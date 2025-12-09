`timescale 1ns / 1ps
`default_nettype none

module udp_payload_extractor (
    input  wire       clk,
    input  wire       rst,

    // Input Stream (RX from MAC)
    input  wire [7:0] s_axis_tdata,
    input  wire       s_axis_tvalid,
    input  wire       s_axis_tlast,
    
    // Output 1: Data FIFO Interface (For Opcode 102030 - Market Data)
    output reg  [7:0] fifo_din,
    output reg        fifo_wr_en,
    input  wire       fifo_full,

    // Output 2: Command Trigger (For Opcode F0E0D0 - Dump Book)
    output reg        trigger_dump,
    
    // NEW Output 3 & 4: Index and Packet Completion Pulse
    output reg [11:0] rx_index_out, // 12-bit Index from the xFEDxxx OpCode
    output reg rx_packet_tlast_pulse,
    
    input wire i_enable_rx
);

    reg [10:0] byte_cnt;
    reg        active_packet;
    reg        drop_packet; 
    reg        is_dump_cmd; // Track which opcode we detected
    reg [11:0] current_index;
    reg [3:0]  r_index_msb_temp;

    // --- FILTER CONSTANTS ---
    // Only accept packets sent TO this FPGA IP
    localparam [31:0] DEST_IP = {8'd192, 8'd168, 8'd1, 8'd50};
    // Only accept packets FROM this Python Script Port (Crucial for filtering Vivado noise)
    localparam [15:0] SRC_PORT = 16'd55555;
    
    // --- OPCODES ---
    localparam [23:0] OP_MARKET_DATA = 24'h102030;
    localparam [23:0] OP_DUMP_BOOK   = 24'hF0E0D0;
    
    //
    
    localparam [15:0] OP_MARKET_PREFIX = 16'hFED0;

    always @(posedge clk) begin
        // Default Pulses
        fifo_wr_en   <= 0;
        trigger_dump <= 0;
        rx_packet_tlast_pulse <= 0;

        if (rst) begin
            byte_cnt      <= 0;
            active_packet <= 0;
            drop_packet   <= 0;
            is_dump_cmd   <= 0;
            current_index <= 12'd0;
            rx_index_out  <= 12'd0; // NEW: Reset index output
        end else if (s_axis_tvalid) begin
            if (!active_packet) begin
                byte_cnt      <= 1;
                active_packet <= 1;
                drop_packet   <= 0;
                is_dump_cmd   <= 0;
                current_index <= 12'd0;
            end else begin
                byte_cnt <= byte_cnt + 1;
            end

            // --- HEADER CHECKS (Standard UDP/IP) ---
            // We verify bytes as they arrive. If any don't match, we flag the packet as 'drop'.
            case (byte_cnt)
                12: if (s_axis_tdata != 8'h08) drop_packet <= 1; // EtherType IPv4
                13: if (s_axis_tdata != 8'h00) drop_packet <= 1;
                23: if (s_axis_tdata != 8'h11) drop_packet <= 1; // Protocol UDP
                
                // Destination IP Check
                30: if (s_axis_tdata != DEST_IP[31:24]) drop_packet <= 1;
                31: if (s_axis_tdata != DEST_IP[23:16]) drop_packet <= 1;
                32: if (s_axis_tdata != DEST_IP[15:8])  drop_packet <= 1;
                33: if (s_axis_tdata != DEST_IP[7:0])   drop_packet <= 1;
                
                // Source Port Check (The "Vivado Filter")
                34: if (s_axis_tdata != SRC_PORT[15:8]) drop_packet <= 1;
                35: if (s_axis_tdata != SRC_PORT[7:0])  drop_packet <= 1;
                
                // --- OPCODE CHECK (Bytes 42, 43, 44) ---
                42: begin
                    // Check first byte of Opcode (F0 or FE)
                    if (s_axis_tdata == OP_DUMP_BOOK[23:16]) is_dump_cmd <= 1;
                    else if (s_axis_tdata != OP_MARKET_PREFIX[15:8]) drop_packet <= 1; // Check for 0xFE
                end
                43: begin
                    // Check second byte (E0 or D) + MSB of the 12 bit number.
                    if (is_dump_cmd) begin
                        if (s_axis_tdata != OP_DUMP_BOOK[15:8]) drop_packet <= 1;
                    end else begin
                        if (s_axis_tdata[7:4] != OP_MARKET_PREFIX[7:4]) begin
                            drop_packet <= 1; // Check for 0xD
                        end else begin 
                            // Is xD copy integer val
                            r_index_msb_temp <= s_axis_tdata[3:0];
                        end
                    end 
                end
                44: begin
                    // Byte 44 is either D0 (Dump) or the LSB of the 12-bit Index (Market Data)
                    if (is_dump_cmd) begin
                        // Old Dump format: Check third byte (D0)
                        if (s_axis_tdata == OP_DUMP_BOOK[7:0] && !drop_packet)
                            trigger_dump <= 1'b1; // Trigger the dump!
                        else drop_packet <= 1;
                    end else begin
                        // Save index number
                        rx_index_out <= {r_index_msb_temp, s_axis_tdata[7:0]};

                    end
                end
            endcase

            // --- DATA EXTRACTION ---
            // We start writing at Byte 45 (Skipping the 42-byte Header + 3-byte Opcode).
            // We only write if:
            // 1. Packet is clean (!drop_packet)
            // 2. It is Market Data (!is_dump_cmd)
            // 3. FIFO has space (!fifo_full)
            if (byte_cnt >= 45 && !drop_packet && !is_dump_cmd && !fifo_full && i_enable_rx) begin
                fifo_din   <= s_axis_tdata;
                fifo_wr_en <= 1'b1;
            end

            if (s_axis_tlast) begin
                if (!drop_packet && !is_dump_cmd) begin
                    // Only pulse TLAST for valid Market Data packets
                    rx_packet_tlast_pulse <= 1'b1;
                end
                active_packet <= 0;
                byte_cnt <= 0;
            end
        end
    end
endmodule