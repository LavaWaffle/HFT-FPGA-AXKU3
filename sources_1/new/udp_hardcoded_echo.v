`timescale 1ns / 1ps
`default_nettype none

module udp_hardcoded_echo (
    input  wire       clk,
    input  wire       rst,

    // AXI Stream Input
    input  wire [7:0] s_axis_tdata,
    input  wire       s_axis_tvalid,
    input  wire       s_axis_tlast,
    output wire       s_axis_tready,

    // AXI Stream Output
    output reg  [7:0] m_axis_tdata,
    output reg        m_axis_tvalid,
    output reg        m_axis_tlast,
    input  wire       m_axis_tready
);

    // --- CONFIGURATION (Change these to match your PC) ---
    // PC MAC Address c8:a3:62:b2:d4:71
    localparam [47:0] TARGET_MAC  =  48'hC8_A3_62_B2_D4_71; //48'hFF_FF_FF_FF_FF_FF; 
    // FPGA MAC Address (e.g., 02:00:00:00:00:00)
    localparam [47:0] MY_MAC      = 48'h02_00_00_00_00_00;
    // PC IP Address (192.168.1.128)
    localparam [31:0] TARGET_IP   = {8'd192, 8'd168, 8'd1, 8'd128};
    // FPGA IP Address (192.168.1.50)
    localparam [31:0] MY_IP       = {8'd192, 8'd168, 8'd1, 8'd50};
    // PC Listening Port (e.g., 55555)
    localparam [15:0] TARGET_PORT = 16'd55555;
    // FPGA Source Port (e.g., 50000)
    localparam [15:0] MY_PORT     = 16'd50000;

    // State Machine
    localparam STATE_IDLE   = 0;
    localparam STATE_STORE  = 1;
    localparam STATE_OUTPUT = 2;

    reg [1:0] state_reg = STATE_IDLE;
    reg [10:0] byte_cnt; 

    // RAM to store ONLY the payload (or whole frame if lazy)
    // We still store the whole frame to keep indexing simple, 
    // but we will overwrite the header on the way out.
    reg [7:0] frame_ram [0:2047];
    reg [10:0] frame_len;
    
    always @(posedge clk) begin
        if (rst) begin
            state_reg <= STATE_IDLE;
            m_axis_tvalid <= 1'b0;
            byte_cnt <= 0;
            m_axis_tlast <= 0;
        end else begin
            case (state_reg)
                STATE_IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    byte_cnt <= 0;
                    if (s_axis_tvalid) begin
                        frame_ram[0] <= s_axis_tdata;
                        byte_cnt <= 1;
                        state_reg <= STATE_STORE;
                    end
                end

                STATE_STORE: begin
                    // We just store the packet. We don't even bother parsing 
                    // IPs/Ports because we are going to overwrite them anyway.
                    // (Assuming you trust the input is meant for you)
                    if (s_axis_tvalid) begin
                        frame_ram[byte_cnt] <= s_axis_tdata;
                        byte_cnt <= byte_cnt + 1;
                        
                        if (s_axis_tlast) begin
                            frame_len <= byte_cnt;
                            state_reg <= STATE_OUTPUT;
                            byte_cnt <= 0;
                        end
                    end
                end

                STATE_OUTPUT: begin
                    if (m_axis_tready) begin
                        m_axis_tvalid <= 1'b1;

                        // --- HARDCODED HEADER GENERATION ---
                        case (byte_cnt)
                            // Ethernet Destination (PC MAC)
                            0: m_axis_tdata <= TARGET_MAC[47:40];
                            1: m_axis_tdata <= TARGET_MAC[39:32];
                            2: m_axis_tdata <= TARGET_MAC[31:24];
                            3: m_axis_tdata <= TARGET_MAC[23:16];
                            4: m_axis_tdata <= TARGET_MAC[15:8];
                            5: m_axis_tdata <= TARGET_MAC[7:0];

                            // Ethernet Source (FPGA MAC)
                            6: m_axis_tdata <= MY_MAC[47:40];
                            7: m_axis_tdata <= MY_MAC[39:32];
                            8: m_axis_tdata <= MY_MAC[31:24];
                            9: m_axis_tdata <= MY_MAC[23:16];
                            10: m_axis_tdata <= MY_MAC[15:8];
                            11: m_axis_tdata <= MY_MAC[7:0];
                            
                            // EtherType (0800 IPv4) - Pass through or hardcode
                            12: m_axis_tdata <= 8'h08;
                            13: m_axis_tdata <= 8'h00;
                            
                            // Force IP Checksum to 0x0000 to prevent PC from dropping packets
                            24: m_axis_tdata <= 8'h00; 
                            25: m_axis_tdata <= 8'h00;

                            // IP Header (Assuming Standard 20 bytes)
                            // We can mostly pass through, but let's hardcode addresses
                            26: m_axis_tdata <= MY_IP[31:24];     // Source IP
                            27: m_axis_tdata <= MY_IP[23:16];
                            28: m_axis_tdata <= MY_IP[15:8];
                            29: m_axis_tdata <= MY_IP[7:0];

                            30: m_axis_tdata <= TARGET_IP[31:24]; // Dest IP
                            31: m_axis_tdata <= TARGET_IP[23:16];
                            32: m_axis_tdata <= TARGET_IP[15:8];
                            33: m_axis_tdata <= TARGET_IP[7:0];

                            // UDP Header
                            34: m_axis_tdata <= MY_PORT[15:8];    // Source Port
                            35: m_axis_tdata <= MY_PORT[7:0];
                            36: m_axis_tdata <= TARGET_PORT[15:8];// Dest Port
                            37: m_axis_tdata <= TARGET_PORT[7:0];
                            
                            // UDP Checksum (Disable it with 0x0000)
                            40: m_axis_tdata <= 8'h00;
                            41: m_axis_tdata <= 8'h00;

                            // DEFAULT: Pass through existing data (IP ver, TTL, Payload, etc.)
                            default: m_axis_tdata <= frame_ram[byte_cnt];
                        endcase

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
    
    assign s_axis_tready = (state_reg != STATE_OUTPUT);

endmodule