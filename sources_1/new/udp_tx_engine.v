`timescale 1ns / 1ps
`default_nettype none

module udp_tx_engine (
    input  wire       clk,
    input  wire       rst,
    // FIFO Interface (No tlast, so we pad if valid goes low)
    input  wire [7:0] s_fifo_tdata,
    input  wire       s_fifo_tvalid,
    output reg        s_fifo_tready,
    
    input wire i_enable_tx,
    
    // AXI Stream Output
    output reg  [7:0] m_axis_tdata,
    output reg        m_axis_tvalid,
    output reg        m_axis_tlast,
    input  wire       m_axis_tready
);

    // --- CONFIGURATION ---
    localparam [47:0] TARGET_MAC = 48'hC8_A3_62_B2_D4_71;
    localparam [47:0] MY_MAC     = 48'h02_00_00_00_00_00;
    localparam [31:0] TARGET_IP  = {8'd192, 8'd168, 8'd1, 8'd128};
    localparam [31:0] MY_IP      = {8'd192, 8'd168, 8'd1, 8'd50};
    localparam [15:0] TARGET_PORT = 16'd55555; 
    localparam [15:0] MY_PORT     = 16'd50000;

    localparam S_IDLE    = 0;
    localparam S_HEADER  = 1;
    localparam S_PAYLOAD = 2;

    reg [1:0] state = S_IDLE;
    reg [10:0] cnt;
    
    // Constant Payload Size
    localparam MAX_PACKET_SIZE = 960; 

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            m_axis_tvalid <= 0;
            s_fifo_tready <= 0;
            m_axis_tlast <= 0;
            cnt <= 0;
        end else begin
            // Default ready to 0
            s_fifo_tready <= 0;

            case (state)
                S_IDLE: begin
                    m_axis_tvalid <= 0;
                    m_axis_tlast  <= 0;
                    cnt <= 0;
                    // Start if we have at least one byte of data
                    if (s_fifo_tvalid && i_enable_tx) state <= S_HEADER;
                end

                S_HEADER: begin
                    if (m_axis_tready) begin
                        m_axis_tvalid <= 1;
                        cnt <= cnt + 1;
                        case (cnt)
                            // Ethernet Header
                            0: m_axis_tdata <= TARGET_MAC[47:40];
                            1: m_axis_tdata <= TARGET_MAC[39:32];
                            2: m_axis_tdata <= TARGET_MAC[31:24];
                            3: m_axis_tdata <= TARGET_MAC[23:16];
                            4: m_axis_tdata <= TARGET_MAC[15:8];
                            5: m_axis_tdata <= TARGET_MAC[7:0];
                            6: m_axis_tdata <= MY_MAC[47:40];
                            7: m_axis_tdata <= MY_MAC[39:32];
                            8: m_axis_tdata <= MY_MAC[31:24];
                            9: m_axis_tdata <= MY_MAC[23:16];
                            10: m_axis_tdata <= MY_MAC[15:8];
                            11: m_axis_tdata <= MY_MAC[7:0];
                            12: m_axis_tdata <= 8'h08; // IPv4
                            13: m_axis_tdata <= 8'h00;
                            
                            // IP Header
                            14: m_axis_tdata <= 8'h45;
                            15: m_axis_tdata <= 8'h00;
                            
                            // [FIX] IP Total Length = 20(IP) + 8(UDP) + 960(Data) = 988 bytes (0x03DC)
                            16: m_axis_tdata <= 8'h03; 
                            17: m_axis_tdata <= 8'hDC; 
                            
                            18: m_axis_tdata <= 8'h00;
                            19: m_axis_tdata <= 8'h00;
                            20: m_axis_tdata <= 8'h00;
                            21: m_axis_tdata <= 8'h00;
                            22: m_axis_tdata <= 8'h40; // TTL
                            23: m_axis_tdata <= 8'h11; // UDP
                            // Checksum 
                            24: m_axis_tdata <= 8'hF3; 
                            25: m_axis_tdata <= 8'h0E;
                            
                            // IP Src/Dst
                            26: m_axis_tdata <= MY_IP[31:24];
                            27: m_axis_tdata <= MY_IP[23:16];
                            28: m_axis_tdata <= MY_IP[15:8];
                            29: m_axis_tdata <= MY_IP[7:0];
                            30: m_axis_tdata <= TARGET_IP[31:24];
                            31: m_axis_tdata <= TARGET_IP[23:16];
                            32: m_axis_tdata <= TARGET_IP[15:8];
                            33: m_axis_tdata <= TARGET_IP[7:0];

                            // UDP Header
                            34: m_axis_tdata <= MY_PORT[15:8];
                            35: m_axis_tdata <= MY_PORT[7:0];
                            36: m_axis_tdata <= TARGET_PORT[15:8];
                            37: m_axis_tdata <= TARGET_PORT[7:0];
                            
                            // [FIX] UDP Length = 8(Header) + 960(Data) = 968 bytes (0x03C8)
                            38: m_axis_tdata <= 8'h03; 
                            39: m_axis_tdata <= 8'hC8; 
                            
                            40: m_axis_tdata <= 8'h00; // Checksum
                            41: begin
                                m_axis_tdata <= 8'h00;
                                state <= S_PAYLOAD;
                                cnt <= 0; // Reset count for payload tracking
                            end
                        endcase
                    end
                end

                S_PAYLOAD: begin
                    if (m_axis_tready) begin
                        m_axis_tvalid <= 1;
                        cnt <= cnt + 1;

                        // Check if we have real data or need to pad
                        if (s_fifo_tvalid) begin
                            m_axis_tdata  <= s_fifo_tdata;
                            s_fifo_tready <= 1; // Ack the FIFO read
                        end else begin
                            // FIFO empty or finished? Pad with Zeros
                            m_axis_tdata  <= 8'h00;
                            s_fifo_tready <= 0; 
                        end

                        // Check for End of Packet
                        // We stop exactly at MAX_PACKET_SIZE - 1 because cnt started at 0
                        if (cnt == MAX_PACKET_SIZE - 1) begin
                            m_axis_tlast <= 1;
                            state <= S_IDLE;
                        end else begin
                            m_axis_tlast <= 0;
                        end
                    end
                end
            endcase
        end
    end
endmodule