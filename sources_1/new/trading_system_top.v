`timescale 1ns / 1ps
`default_nettype none

module trading_system_top (
    // Clocking
    input  wire        clk_udp,       // 125 MHz (Network Side)
    input  wire        rst_udp,
    input  wire        clk_engine,    // 200 MHz (Engine Side)
    input  wire        rst_engine,

    // UDP RX Stream (From MAC)
    input  wire [7:0]  rx_axis_tdata,
    input  wire        rx_axis_tvalid,
    input  wire        rx_axis_tlast,
    
    // UART RX Stream (From Other Part, ex Spartan or Comp)
    input  wire [7:0]  uart_rx_data_out,
    input  wire        uart_rx_data_valid,        

    // UDP TX Interface (From Return FIFO to UDP TX Engine)
    output wire [7:0]  tx_fifo_tdata,
    output wire        tx_fifo_tvalid, // FIFO not empty
    input  wire        tx_fifo_tready, // UDP Engine Read Enable
    
    // UART Tx Interface (From UART Return FIFO to UART Transmitter)
    output wire [7:0]  uart_tx_data_in,
    output wire        uart_tx_data_valid,
    input  wire        uart_tx_ready,
    
    output wire o_enable_udp_tx,
    
    // UDP ACK
    output wire [11:0] o_tx_ack_index,
    output wire o_tx_ack_start,
    input wire i_tx_ack_done,
    
     // Outputs from Order Book (for debugging/LEDs)
    output wire [31:0] trade_info,
    output wire        trade_valid,
    output wire        engine_busy,
    output wire [3:0]  leds,
    output wire [31:0] debug_ob_data,
    output wire        debug_input_fifo_empty,
    output wire        debug_input_fifo_full,
    
    // --- NEW DEBUG PORTS FOR ILA ---
    output wire [2:0] debug_fsm_state,          // FSM State (200 MHz)
    output wire debug_rx_tlast_synced,          // Packet Received Pulse (200 MHz)
    output wire debug_tx_ack_enable
);

    // --- NEW: SYSTEM MANAGER FSM PARAMETERS (200 MHz Domain) ---
    localparam S0_FETCH_DATA   = 3'd0;
    localparam S0_1_SEND_ACK   = 3'd1; // Sub-state to pulse UDP TX
    localparam S0_2_WAIT_DATA  = 3'd2; // Sub-state to wait for server response/timeout
    localparam S1_MARKET_BOT   = 3'd3;
    localparam S2_DUMP_CHECK   = 3'd4;
    localparam S2_DUMPING      = 3'd5;
    
    // Timeout Limit (500,000 cycles at 200MHz = 2.5ms) - Adjust as needed for network latency
//    localparam FETCH_TIMEOUT_LIMIT = 20'd500_000;
//    localparam FETCH_TIMEOUT_LIMIT = 32'd100_000_000; // 40m @ 200 MHz -> 200ms Period. 5 Per sec in Idle
    localparam FETCH_TIMEOUT_LIMIT = 32'd10_000; // Use this only for test benches
       
    reg r_dump_request = 1'b0;
    wire uart_trigger_dump_raw;
    // -------------------------------------------------------------------------
    // 0. UART EXTRACTOR (200 MHz) - Now with Trigger Logic
    // -------------------------------------------------------------------------
    uart_payload_extractor uart_extractor_inst (
        .clk(clk_engine),
        .rst(rst_engine),
        .uart_rx_data_out(uart_rx_data_out),
        .uart_rx_data_valid(uart_rx_data_valid),
        .trigger_dump(uart_trigger_dump_raw)
    );

    // -------------------------------------------------------------------------
    // 1. EXTRACTOR (125 MHz) - Now with Trigger Logic
    // -------------------------------------------------------------------------
    wire [7:0] input_fifo_din;
    wire       input_fifo_wr_en;
    wire       input_fifo_full;
    wire       trigger_dump_raw;
    
    wire [11:0] rx_index_out_raw; 
    wire rx_packet_tlast_pulse_raw;

    udp_payload_extractor extractor_inst (
        .clk(clk_udp),
        .rst(rst_udp),
        .s_axis_tdata(rx_axis_tdata),
        .s_axis_tvalid(rx_axis_tvalid),
        .s_axis_tlast(rx_axis_tlast),
        .fifo_din(input_fifo_din),
        .fifo_wr_en(input_fifo_wr_en),
        .fifo_full(input_fifo_full),
        .trigger_dump(trigger_dump_raw),
        .rx_index_out(rx_index_out_raw), 
        .rx_packet_tlast_pulse(rx_packet_tlast_pulse_raw),
        
        .i_enable_rx(r_enable_rx_synced)
    );

    // Below CDC_UDP_to_ENGINE pulse
    wire [11:0] rx_index_synced;
    wire rx_tlast_pulse_synced;
    
    // CDC for 12-bit Index (125 MHz -> 200 MHz)
    sync_data #(.WIDTH(12)) CDC_INDEX (
        .src_clk(clk_udp), .dest_clk(clk_engine),
        .src_in(rx_index_out_raw), .dest_out(rx_index_synced)
    );
    
    // CDC for TLAST Pulse (125 MHz -> 200 MHz)
    xpm_cdc_pulse # (
       .DEST_SYNC_FF(4),     // Default: Number of synchronizer stages (2-10)
      .INIT_SYNC_FF(1),     // *** FIX: Enable simulation init values (0 or 1)
      .REG_OUTPUT(0),       // Default: 0=combinatorial output, 1=registered
      .RST_USED(1)          // Default: 1=Resets implemented
    ) CDC_TLAST_PULSE (
        .src_pulse(rx_packet_tlast_pulse_raw),
        .src_clk(clk_udp), 
        .src_rst(rst_udp),
        .dest_clk(clk_engine),
        .dest_rst(rst_engine),
        .dest_pulse(rx_tlast_pulse_synced)
    );
    
    wire udp_trigger_synced; // Result of 125MHz -> 200MHz CDC Pulse
    
    xpm_cdc_pulse #(
      .DEST_SYNC_FF(4),     // Default: Number of synchronizer stages (2-10)
      .INIT_SYNC_FF(1),     // *** FIX: Enable simulation init values (0 or 1)
      .REG_OUTPUT(0),       // Default: 0=combinatorial output, 1=registered
      .RST_USED(1)          // Default: 1=Resets implemented
    ) CDC_UDP_to_ENGINE (
      .dest_pulse(udp_trigger_synced), // Output pulse
      .dest_clk(clk_engine),           // 200 MHz clock
      .dest_rst(rst_engine),           // *** FIX: Destination reset signal
      .src_clk(clk_udp),               // 125 MHz clock
      .src_pulse(trigger_dump_raw),    // Input pulse
      .src_rst(rst_udp)                // *** FIX: Source reset signal
    );
    
    wire combined_dump_pulse;

    // Completely safe both at 200 Mhz
    assign combined_dump_pulse = udp_trigger_synced | uart_trigger_dump_raw; 

    // -------------------------------------------------------------------------
    // 2. INPUT FIFO (8-bit -> 32-bit, FWFT)
    // -------------------------------------------------------------------------
    wire [31:0] fifo_dout_raw;
    wire        fifo_empty;
    wire        fifo_rd_en;
    
    fifo_generator_0 input_fifo (
        .rst(rst_udp),
        .wr_clk(clk_udp),
        .din(input_fifo_din),
        .wr_en(input_fifo_wr_en),
        .full(input_fifo_full),
//        .wr_rst_busy(),
        
        .rd_clk(clk_engine),
        .dout(fifo_dout_raw),
        .rd_en(fifo_rd_en),
        .empty(fifo_empty)
        //.rd_rst_busy()
    );

    // -------------------------------------------------------------------------
    // 3. GLUE LOGIC (200 MHz)
    // -------------------------------------------------------------------------
    // Only read if we have data AND engine is ready
    assign fifo_rd_en = (!fifo_empty) && (!engine_busy);
    
    // NOP Filter: Only valid if data is non-zero
    wire [31:0] ob_input_data;
    // Endianness Swap (Big -> Little)
//    assign ob_input_data = {fifo_dout_raw[7:0], fifo_dout_raw[15:8], fifo_dout_raw[23:16], fifo_dout_raw[31:24]};
    assign ob_input_data = fifo_dout_raw;    
    wire ob_input_valid_fsm_gated;
    assign ob_input_valid_fsm_gated = fifo_rd_en && (ob_input_data != 32'd0);
    assign debug_ob_data  = ob_input_data;

    // --- 3. GLUE LOGIC (200 MHz) - KEEP ORIGINAL GLUE LOGIC HERE ---
// ... (original glue logic for ob_input_valid, fifo_rd_en, etc.)

    // -------------------------------------------------------------------------
    // 4. SYSTEM MANAGER FSM (200 MHz)
    // -------------------------------------------------------------------------
    // NEW REGISTERS
    reg [2:0] r_System_State = S0_FETCH_DATA;
    reg [2:0] r_System_State_prev = S0_FETCH_DATA;
    reg [11:0] r_Last_Index = 12'd0;
    reg [31:0] r_Fetch_Timer = 32'd0; // Used for S0.2 timeout
    reg [19:0] r_Bot_Timer = 20'd0;
    wire tx_ack_done; // Internal wire to connect to external port
    assign tx_ack_done = i_tx_ack_done;
    // Control Signals
    reg r_enable_rx = 1'b0;
    reg r_enable_tx_ack = 1'b0;
    reg r_enable_bot = 1'b0;
    
    // New wire to synchronize the RX enable flag
    wire r_enable_rx_synced;
    
    // New wire to control the final valid pulse to the Order Book Engine    
    sync_data #(.WIDTH(1)) CDC_RX_ENABLE (
        .src_clk(clk_engine), .dest_clk(clk_udp),
        .src_in(r_enable_rx), .dest_out(r_enable_rx_synced)
    );
    
    // The combined dump command remains active for dump checks:
    // assign start_dump_command = udp_trigger_synced | uart_trigger_dump_raw;
    
    always @(posedge clk_engine) begin
        if (combined_dump_pulse) begin
            r_dump_request <= 1'b1;
        end
    
        r_System_State_prev <= r_System_State;
        if (rst_engine) begin
            r_System_State <= S0_FETCH_DATA;
            r_System_State_prev <= S0_FETCH_DATA;
            r_Last_Index <= 12'd0;
            r_Fetch_Timer <= 32'd0;
            r_enable_rx <= 1'b0;
            r_enable_tx_ack <= 1'b0;
            r_enable_bot <= 1'b0;
            r_Bot_Timer <= 20'd0;
        end else begin
            // Timer Logic (active only in S0_2_WAIT_DATA)
            if (r_System_State == S0_2_WAIT_DATA) begin
                r_Fetch_Timer <= r_Fetch_Timer + 1;
            end else begin
                r_Fetch_Timer <= 32'd0;
            end
            // S1 Market Bot Timer
            if (r_System_State == S1_MARKET_BOT) begin
                r_Bot_Timer <= r_Bot_Timer + 1;
            end else begin
                r_Bot_Timer <= 20'd0;
            end
    
            // State Transitions and Control
            r_enable_rx <= 1'b0; // Default off
            r_enable_tx_ack <= 1'b0;
            r_enable_bot <= 1'b0;
    
            case (r_System_State)
                S0_FETCH_DATA: begin
                    // State to start the sequence. Immediately move to S0.1
                    r_System_State <= S0_1_SEND_ACK;
                end
    
                S0_1_SEND_ACK: begin
                    // Send the ACK message containing r_Last_Index
                    r_enable_tx_ack <= 1'b1;
                    if (tx_ack_done) begin
                        r_System_State <= S0_2_WAIT_DATA;
                    end
                end
    
                S0_2_WAIT_DATA: begin
                    // Enable RX, listen for response
                    r_enable_rx <= 1'b1;
    
                    // Condition 1: Packet Received (Index updated and TLAST pulsed)
                    if (rx_tlast_pulse_synced) begin
                        r_Last_Index <= rx_index_synced; // Update the acknowledged index
                        r_System_State <= S1_MARKET_BOT; // Move to processing
                    end
                    
                    // Condition 2: Timeout
                    else if (r_Fetch_Timer == FETCH_TIMEOUT_LIMIT) begin
                        r_System_State <= S1_MARKET_BOT; // Move to processing
                    end
                end
    
                S1_MARKET_BOT: begin
                    r_enable_bot <= 1'b1;
                    if (r_Bot_Timer == 5000) begin // Use the dedicated Bot Timer
                        r_System_State <= S2_DUMP_CHECK;
                    end
                end
                
                S2_DUMP_CHECK: begin
                    // Check if any dump requests are pending 
                    if (r_dump_request) begin
                        // GO TO DUMPING
                        r_System_State <= S2_DUMPING; 
                    end else begin
                        // No dump requested Return to fetch cycle.
                        r_System_State <= S0_FETCH_DATA;
                    end
                end
                
                S2_DUMPING: begin
                    if (engine_busy | r_dump_request) begin
                        r_System_State <= S2_DUMPING;
                        r_dump_request <= 1'b0;
                    end else begin 
                        r_System_State <= S0_FETCH_DATA;
                    end
                
                end
    
                default: r_System_State <= S0_FETCH_DATA;
            endcase
        end
    end
    
    // --- APPLY CONTROL SIGNALS TO SUB-MODULES ---

    // 1. Acknowledge Generator Interface (Inputs to UDP ACK Generator in fpga_top)
    // Assumes fpga_top directly receives and passes these through.
    assign o_tx_ack_index = r_Last_Index;
    assign o_tx_ack_start = (r_System_State == S0_1_SEND_ACK);

    wire tx_data_enable;
    assign tx_data_enable = (r_System_State == S1_MARKET_BOT) | (r_System_State == S2_DUMP_CHECK);
    assign o_enable_udp_tx = tx_data_enable;
    // -------------------------------------------------------------------------
    // 4. ORDER BOOK ENGINE (200 MHz)
    // -------------------------------------------------------------------------
//    wire [31:0] trade_info;
//    wire        trade_valid;

    wire start_dump_command = r_dump_request && (r_System_State == S2_DUMP_CHECK);

    order_book_top ob_inst (
        .clk(clk_engine),
        .rst_n(!rst_engine),
        
        // Input
        .input_valid(ob_input_valid_fsm_gated),
        .input_data(ob_input_data),
        .start_dump(start_dump_command), // <--- CONNECT THIS to your Engine's Dump Trigger
        
        // Flow Control
        .engine_busy(engine_busy),
        
        // Output (Trades AND Dump Data go here)
        .trade_valid(trade_valid),
        .trade_info(trade_info),
        .leds(leds)
    );

    // -------------------------------------------------------------------------
    // 5. RETURN FIFO (32-bit -> 8-bit, FWFT) - NEW!
    // -------------------------------------------------------------------------
    // This captures Trades/Dumps and sends them back to the network.
    
    fifo_generator_1 return_fifo (
        .rst(rst_engine),
        
        // WRITE SIDE (Engine 200 MHz)
        .wr_clk(clk_engine),
        .din(trade_info),     // We assume Little Endian from Engine
        .wr_en(trade_valid),  // Write whenever engine outputs data
        .full(),              // If full, we lose data (add 'full' check to engine if critical)
        
        // READ SIDE (Network 125 MHz)
        .rd_clk(clk_udp),
        .dout(tx_fifo_tdata),
        .rd_en(tx_fifo_tready),
        .empty(tx_fifo_empty)
    );
    
    wire tx_fifo_empty;
    assign tx_fifo_tvalid = !tx_fifo_empty; // FWFT Logic
    
    assign debug_input_fifo_empty = fifo_empty;
    assign debug_input_fifo_full  = input_fifo_full;

    fifo_generator_2 uart_return_fifo (
        .srst(rst_engine),
        .clk(clk_engine),
        
        // WRITE SIDE OB Engine(200 MHz)
        .din(trade_info), // 32 bits
        .wr_en(trade_valid),
        .full(), // Ehh prob not an issue
        
        .dout(uart_tx_data_in), // 8 bits
        .rd_en(uart_tx_ready),
        .empty(uart_tx_fifo_empty)
    );
    
    wire uart_tx_fifo_empty;
    assign uart_tx_data_valid = !uart_tx_fifo_empty;

    assign debug_fsm_state = r_System_State;
    assign debug_rx_tlast_synced = rx_tlast_pulse_synced;
    assign debug_tx_ack_enable = r_enable_tx_ack;

endmodule