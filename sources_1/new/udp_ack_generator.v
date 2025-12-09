`timescale 1ns / 1ps
`default_nettype none

module udp_ack_generator (
    input  wire        clk,
    input  wire        rst,

    // Control and Data from System FSM (200 MHz domain)
    input  wire        i_start_ack,    // Pulse from FSM (S0_1_SEND_ACK)
    input  wire [11:0] i_last_index,   // The 12-bit index to acknowledge
    output wire        o_tx_done,      // Pulse high when packet transmission finishes

    // AXI Stream Output to MAC Arbiter (125 MHz domain - must be synchronized later)
    output reg  [7:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast
);

    // --- CONFIGURATION (Must match MAC/IP settings) ---
    localparam [47:0] TARGET_MAC = 48'hC8_A3_62_B2_D4_71;
    localparam [47:0] MY_MAC     = 48'h02_00_00_00_00_00;
    localparam [31:0] TARGET_IP  = {8'd192, 8'd168, 8'd1, 8'd128};
    localparam [31:0] MY_IP      = {8'd192, 8'd168, 8'd1, 8'd50};
    localparam [15:0] TARGET_PORT = 16'd55555; 
    localparam [15:0] MY_PORT     = 16'd50000;
    
    // NEW OpCode for ACK (e.g., 0xAA0000)
    localparam [23:0] OP_ACK     = 24'hAA0000; 

    // Total length: 42B Header + 3B OpCode + 2B Index + 13B Padding = 60 bytes (Min Ethernet Frame)
    localparam FRAME_SIZE_BYTES = 60; // Standard Minimum Ethernet Frame Size
    localparam PAYLOAD_LEN_UDP  = 18; // 3B OpCode + 2B Index + 13B Padding = 18 bytes
    localparam TOTAL_LEN_IP     = 54; // 20B IP + 8B UDP + 18B Payload = 46 bytes (0x0036)

    // --- FSM States ---
    localparam S_IDLE    = 3'd0;
    localparam S_HEADER  = 3'd1;
    localparam S_PAYLOAD = 3'd2;
    localparam S_DONE    = 3'd3;

    // --- REGISTERS ---
    reg [2:0]  state = S_IDLE;
    reg [5:0]  cnt_byte = 0; // Counts up to 59
    reg [11:0] r_index_to_send = 0;
    reg        r_tx_done_pulse = 0;

    assign o_tx_done = r_tx_done_pulse;

    always @(posedge clk) begin
        // --- Defaults ---
        m_axis_tvalid <= 1'b0;
        r_tx_done_pulse <= 1'b0;
        m_axis_tlast <= 1'b0;
        
        if (rst) begin
            state <= S_IDLE;
            cnt_byte <= 0;
        end else begin
            
            case (state)
                S_IDLE: begin
                    // Wait for start pulse from FSM
                    if (i_start_ack) begin
                        r_index_to_send <= i_last_index; // Latch index from FSM
                        state <= S_HEADER;
                        cnt_byte <= 0;
                    end
                end

                S_HEADER: begin
                    if (m_axis_tready) begin
                        m_axis_tvalid <= 1'b1;
                        cnt_byte <= cnt_byte + 1;
                        
                        case (cnt_byte)
                            // Ethernet Header (0-13)
                            0: m_axis_tdata <= TARGET_MAC[47:40]; // Dst MAC
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
                            13: m_axis_tdata <= 8'h00; // EthType LSB
                            
                            // IP Header (14-33)
                            14: m_axis_tdata <= 8'h45; // Version/IHL
                            15: m_axis_tdata <= 8'h00;
                            // IP Total Length is fixed at 54 (0x0036)
                            16: m_axis_tdata <= 8'h00; 
                            17: m_axis_tdata <= 8'h36; 
                            
                            18: m_axis_tdata <= 8'h00;
                            19: m_axis_tdata <= 8'h00;
                            20: m_axis_tdata <= 8'h00;
                            21: m_axis_tdata <= 8'h00;
                            22: m_axis_tdata <= 8'h40; // TTL
                            23: m_axis_tdata <= 8'h11; // UDP
                            
                            // CHECK SUM
                            24: m_axis_tdata <= 8'h76;  // Checksum MSB
                            25: m_axis_tdata <= 8'h42;
                            
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
                            // UDP Length is 18B Payload + 8B Header = 26B (0x001A)
                            38: m_axis_tdata <= 8'h00; 
                            39: m_axis_tdata <= 8'h1A; 

                            40: m_axis_tdata <= 8'h00; // Checksum MSB (Set to 0)
                            41: begin
                                m_axis_tdata <= 8'h00; // Checksum LSB (Set to 0). Transition to Payload.
                                state <= S_PAYLOAD;
                                cnt_byte <= 0; // Reset counter for payload
                            end

                            default: m_axis_tdata <= 8'h00; // Default fill for ignored header bytes
                        endcase
                    end
                end

                S_PAYLOAD: begin
                    if (m_axis_tready) begin
                        m_axis_tvalid <= 1'b1;
                        cnt_byte <= cnt_byte + 1;
                        
                        case (cnt_byte)
                            // 1. ACK OpCode (3 Bytes: AA0000)
                            0: m_axis_tdata <= OP_ACK[23:16];
                            1: m_axis_tdata <= OP_ACK[15:8];
                            2: m_axis_tdata <= OP_ACK[7:0];

                            // 2. Index Payload (2 Bytes, Big Endian: MSB 4 bits, LSB 8 bits)
                            3: m_axis_tdata <= r_index_to_send[11:8]; // MSB 4 bits + 4 padding bits
                            4: m_axis_tdata <= r_index_to_send[7:0];  // LSB 8 bits

                            // 3. Padding (Bytes 5 to 59 = 55 bytes remaining)
                            FRAME_SIZE_BYTES - 1: begin
                                m_axis_tdata <= 8'h00; 
                                m_axis_tlast <= 1'b1;
                                r_tx_done_pulse <= 1'b1; // Pulse Done
                                state <= S_IDLE; // Done
                            end

                            default: m_axis_tdata <= 8'h00; // Padding
                        endcase
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule