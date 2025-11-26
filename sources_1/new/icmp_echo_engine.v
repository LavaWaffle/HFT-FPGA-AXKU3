/*
 * ICMP Echo Engine
 * * Listens for ICMP Echo Requests (Ping), swaps addresses, 
 * adjusts checksum, and loops packet back.
 */
`timescale 1ns / 1ps
`default_nettype none

module icmp_echo_engine (
    input  wire       clk,
    input  wire       rst,

    // AXI Stream Input (RX from MAC)
    input  wire [7:0] s_axis_tdata,
    input  wire       s_axis_tvalid,
    input  wire       s_axis_tlast,
    output wire       s_axis_tready,

    // AXI Stream Output (TX to Arbiter)
    output reg  [7:0] m_axis_tdata,
    output reg        m_axis_tvalid,
    output reg        m_axis_tlast,
    input  wire       m_axis_tready,

    // LED indicator
    output reg        ping_detect
);

    // State Machine
    localparam STATE_IDLE        = 0;
    localparam STATE_PARSE       = 1;
    localparam STATE_OUTPUT      = 2;
    localparam STATE_DROP        = 3;

    reg [2:0] state_reg = STATE_IDLE;
    reg [10:0] byte_cnt; // Counts bytes in frame

    // Packet Storage (Max Frame ~1518 bytes)
    // Simple RAM to store packet while we verify it's a ping
    reg [7:0] frame_ram [0:2047]; 
    reg [10:0] frame_len;
    
    // Header Capture Registers
    reg [47:0] dest_mac, src_mac;
    reg [31:0] src_ip, dest_ip;
    reg [15:0] icmp_checksum;
    reg [15:0] new_checksum;
    
    // Flags
    reg is_ipv4;
    reg is_icmp;
    reg is_echo_req;

    always @(posedge clk) begin
        if (rst) begin
            state_reg <= STATE_IDLE;
//            s_axis_tready_reg <= 1'b0;
            m_axis_tvalid <= 1'b0;
            ping_detect <= 1'b0;
            byte_cnt <= 0;
        end else begin
            // Default outputs
            ping_detect <= 1'b0;

            case (state_reg)
                STATE_IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    byte_cnt <= 0;
                    is_ipv4 <= 0;
                    is_icmp <= 0;
                    is_echo_req <= 0;
                    
                    if (s_axis_tvalid) begin
                        // Start capturing
                        frame_ram[0] <= s_axis_tdata;
                        byte_cnt <= 1;
                        state_reg <= STATE_PARSE;
                    end
                end

                STATE_PARSE: begin
                    if (s_axis_tvalid) begin
                        frame_ram[byte_cnt] <= s_axis_tdata;
                        byte_cnt <= byte_cnt + 1;

                        // Parsing Logic (Hardcoded offsets for standard Ethernet frames)
                        // Note: This assumes no VLAN tagging for simplicity.
                        // Byte 12-13: EtherType
                        if (byte_cnt == 13 && {frame_ram[12], s_axis_tdata} == 16'h0800)
                            is_ipv4 <= 1;
                        
                        // Byte 23: Protocol (Inside IP Header)
                        if (byte_cnt == 23 && s_axis_tdata == 8'h01)
                            is_icmp <= 1;

                        // Byte 26-29: Source IP (Capture for swap)
                        if (byte_cnt == 26) src_ip[31:24] <= s_axis_tdata;
                        if (byte_cnt == 27) src_ip[23:16] <= s_axis_tdata;
                        if (byte_cnt == 28) src_ip[15:8]  <= s_axis_tdata;
                        if (byte_cnt == 29) src_ip[7:0]   <= s_axis_tdata;

                        // Byte 34: ICMP Type
                        if (byte_cnt == 34 && s_axis_tdata == 8'h08)
                            is_echo_req <= 1;

                        // Byte 36-37: ICMP Checksum (Capture to update)
                        if (byte_cnt == 36) icmp_checksum[15:8] <= s_axis_tdata;
                        if (byte_cnt == 37) icmp_checksum[7:0]  <= s_axis_tdata;

                        if (s_axis_tlast) begin
                            frame_len <= byte_cnt;
                            // Only reply if IPv4 + ICMP + Echo Request
                            if (is_ipv4 && is_icmp && is_echo_req) begin
                                // Pre-calculate new checksum: Old + 0x0800 (Type 8->0 delta)
                                // Simple 1's complement addition logic
                                {checksum_carry, new_checksum} <= icmp_checksum + 16'h0800;
                                state_reg <= STATE_OUTPUT;
                                byte_cnt <= 0;
                                ping_detect <= 1'b1; // Pulse LED
                            end else begin
                                state_reg <= STATE_IDLE; // Ignore other packets
                            end
                        end
                    end
                end

                STATE_OUTPUT: begin
                    if (m_axis_tready) begin
                        m_axis_tvalid <= 1'b1;
                        
                        // Data Modification MUX
                        if (byte_cnt < 6) begin
                            // Dest MAC = Old Source MAC
                            m_axis_tdata <= frame_ram[byte_cnt + 6]; 
                        end else if (byte_cnt < 12) begin
                            // Source MAC = Old Dest MAC (our MAC)
                            m_axis_tdata <= frame_ram[byte_cnt - 6];
                        end else if (byte_cnt >= 26 && byte_cnt <= 29) begin
                            // Source IP = Old Dest IP (Our IP)
                            m_axis_tdata <= frame_ram[byte_cnt + 4]; 
                        end else if (byte_cnt >= 30 && byte_cnt <= 33) begin
                            // Dest IP = Old Src IP
                            m_axis_tdata <= src_ip[(33-byte_cnt)*8 +: 8];
                        end else if (byte_cnt == 34) begin
                            // ICMP Type: Echo Reply (0)
                            m_axis_tdata <= 8'h00;
                        end else if (byte_cnt == 36) begin
                            // New Checksum High Byte (handle carry wrap around)
                            m_axis_tdata <= new_checksum[15:8] + checksum_carry;
                        end else if (byte_cnt == 37) begin
                            // New Checksum Low Byte
                            m_axis_tdata <= new_checksum[7:0];
                        end else begin
                            // Pass through payload data
                            m_axis_tdata <= frame_ram[byte_cnt];
                        end

                        // End of Frame
                        if (byte_cnt == frame_len) begin
                            m_axis_tlast <= 1'b1;
                            state_reg <= STATE_IDLE;
                        end else begin
                            m_axis_tlast <= 1'b0;
                            byte_cnt <= byte_cnt + 1;
                        end
                    end
                end
            endcase
        end
    end
    
    reg checksum_carry;
    
    // Assign Ready (We are always ready to receive unless processing)
    assign s_axis_tready = (state_reg == STATE_IDLE) || (state_reg == STATE_PARSE);

endmodule
`default_nettype wire