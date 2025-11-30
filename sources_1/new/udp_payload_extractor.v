`timescale 1ns / 1ps
`default_nettype none

module udp_payload_extractor (
    input  wire       clk,          
    input  wire       rst,

    // Input Stream (RX from MAC)
    input  wire [7:0] s_axis_tdata,
    input  wire       s_axis_tvalid,
    input  wire       s_axis_tlast,
    
    // FIFO Interface
    output reg  [7:0] fifo_din,
    output reg        fifo_wr_en,
    input  wire       fifo_full
);

    reg [10:0] byte_cnt;
    reg        active_packet;
    reg        drop_packet; // NEW: The "Poison Pill" flag

    // --- HARDCODED FILTER VALUES ---
    // Target IP: 192.168.1.50 (FPGA)
    localparam [31:0] FILTER_DEST_IP = {8'd192, 8'd168, 8'd1, 8'd50};
    // Source Port: 55555 (Python) -> Hex D903
    localparam [15:0] FILTER_SRC_PORT = 16'd55555;
    // Magic Payload Signature (First 3 bytes of data)
    localparam [23:0] FILTER_MAGIC_BYTES = 24'h670420;

    always @(posedge clk) begin
        if (rst) begin
            byte_cnt      <= 0;
            fifo_wr_en    <= 0;
            fifo_din      <= 0;
            active_packet <= 0;
            drop_packet   <= 0;
        end else begin
            fifo_wr_en <= 0; 

            if (s_axis_tvalid) begin
                if (!active_packet) begin
                    // Start of new packet
                    byte_cnt      <= 1; // Start counting at 1
                    active_packet <= 1;
                    drop_packet   <= 0; // Assume valid until proven otherwise
                    
                    // Note: If byte 0 doesn't match Dest MAC, we could drop here, 
                    // but usually the Hardware MAC filters that for us.
                end else begin
                    byte_cnt <= byte_cnt + 1;
                end

                // --- HEADER FILTERING LOGIC ---
                // We check bytes as they fly by. If any mismatch, we set drop_packet = 1.
                // Once set, it stays 1 until the packet ends.
                
                case (byte_cnt)
                    // Byte 12-13: EtherType (Must be 0x0800 IPv4)
                    12: if (s_axis_tdata != 8'h08) drop_packet <= 1;
                    13: if (s_axis_tdata != 8'h00) drop_packet <= 1;

                    // Byte 23: IP Protocol (Must be 0x11 UDP)
                    23: if (s_axis_tdata != 8'h11) drop_packet <= 1;

                    // Byte 30-33: Destination IP (Must match FPGA IP)
                    30: if (s_axis_tdata != FILTER_DEST_IP[31:24]) drop_packet <= 1;
                    31: if (s_axis_tdata != FILTER_DEST_IP[23:16]) drop_packet <= 1;
                    32: if (s_axis_tdata != FILTER_DEST_IP[15:8])  drop_packet <= 1;
                    33: if (s_axis_tdata != FILTER_DEST_IP[7:0])   drop_packet <= 1;

                    // Byte 34-35: UDP Source Port (Must match 55555)
                    // This ensures ONLY your Python script can trigger the market.
                    34: if (s_axis_tdata != FILTER_SRC_PORT[15:8]) drop_packet <= 1;
                    35: if (s_axis_tdata != FILTER_SRC_PORT[7:0])  drop_packet <= 1;

                    // Byte 42-44: Magic Signature (0x670420)
                    // Checks the first 3 bytes of the payload to confirm it's from our Trader
                    42: if (s_axis_tdata != FILTER_MAGIC_BYTES[23:16]) drop_packet <= 1;
                    43: if (s_axis_tdata != FILTER_MAGIC_BYTES[15:8])  drop_packet <= 1;
                    44: if (s_axis_tdata != FILTER_MAGIC_BYTES[7:0])   drop_packet <= 1;
                endcase

                // --- PAYLOAD EXTRACTION ---
                // UDP Payload starts at Byte 42. 
                // We SKIP the first 3 bytes (Magic Bytes) and start writing at Byte 45.
                // This ensures the Order Book only receives pure data.
                if (byte_cnt >= 45) begin
                    // Only write if FIFO is ready AND packet is clean
                    if (!fifo_full && !drop_packet) begin
                        fifo_din   <= s_axis_tdata;
                        fifo_wr_en <= 1'b1;
                    end
                end

                // End of Packet
                if (s_axis_tlast) begin
                    active_packet <= 0;
                    byte_cnt      <= 0;
                    // drop_packet resets on next 'if (!active_packet)'
                end
            end
        end
    end
endmodule