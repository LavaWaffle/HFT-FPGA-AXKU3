`timescale 1ns / 1ps

// Mock macros needed for the test bench to access internal signals
`ifndef PRICE
    `define PRICE(x) x[31:16]
    `define IS_BUY(x) x[15]
    `define IS_BOT(x) x[14]
    `define QTY(x)    x[13:0]
`endif
// Include order_defines.v in your compilation environment.

module tb_fsm_sequential;

    // =================================================================
    // 1. Signals & Clocks
    // =================================================================
    reg         clk_udp = 0;     // 125 MHz
    reg         rst_udp = 1;
    reg [7:0]   rx_axis_tdata = 0;
    reg         rx_axis_tvalid = 0;
    reg         rx_axis_tlast = 0;
    
    reg         clk_engine = 0;   // 200 MHz
    reg         rst_engine = 1;

    // --- Trading System Wires (Outputs) ---
    wire [31:0] trade_info;
    wire        trade_valid;
    wire        engine_busy;
    wire debug_input_fifo_empty;
    
    // --- Internal Monitor Wires ---
    wire [2:0] r_System_State_monitor;
    
    // FSM States for Monitoring
    localparam S0_FETCH_DATA   = 3'd0;
    localparam S0_1_SEND_ACK   = 3'd1; 
    localparam S0_2_WAIT_DATA  = 3'd2; 
    localparam S1_MARKET_BOT   = 3'd3;
    localparam S2_DUMP_CHECK   = 3'd4;
    
    // Constants
    localparam [31:0] DEST_IP  = {8'd192, 8'd168, 8'd1, 8'd50};    
    localparam [15:0] SRC_PORT = 16'd55555;                          
    localparam [23:0] OP_MARKET = 24'hFED000; // Mock opcode for Market data (xFEDxxx family)
    localparam [23:0] OP_DUMP   = 24'hF0E0D0; // Mock opcode for Dump command
    localparam BOT_DELAY_CLKS = 5000;
    
    // GLOBAL BUFFER for Packet Generation
    reg [31:0] order_batch [0:63]; 
    
    // Dummy outputs/inputs for simplified TB instantiation
    wire [7:0] dummy_tdata;
    wire dummy_tvalid;
    wire [11:0] dummy_ack_index;
    wire dummy_ack_start;
    wire [31:0] dummy_ob_data;
    wire enable_udp_tx;

    // =================================================================
    // 2. Instantiate UUT (Trading System Top)
    // =================================================================
    
    trading_system_top uut (
        .clk_udp(clk_udp),
        .rst_udp(rst_udp),
        .clk_engine(clk_engine),
        .rst_engine(rst_engine),
        
        // RX Stream (Stimulus)
        .rx_axis_tdata(rx_axis_tdata),
        .rx_axis_tvalid(rx_axis_tvalid),
        .rx_axis_tlast(rx_axis_tlast),
        
        // UART Interfaces (Ignored)
        .uart_rx_data_out(8'b0),
        .uart_rx_data_valid(1'b0),
        .uart_tx_data_in(),
        .uart_tx_data_valid(),
        .uart_tx_ready(1'b1),

        // UDP TX Interface (Consume instantly)
        .tx_fifo_tdata(dummy_tdata),
        .tx_fifo_tvalid(dummy_tvalid),
        .tx_fifo_tready(1'b1), 

        // UDP ACK Interface (Mock instant done)
        .o_tx_ack_index(dummy_ack_index),
        .o_tx_ack_start(dummy_ack_start),
        .i_tx_ack_done(1'b1), // MOCK: Assume ACK Generator is always instantly done

        // Debug/Status Wires
        .trade_info(trade_info),
        .trade_valid(trade_valid),
        .engine_busy(engine_busy),
        .debug_ob_data(dummy_ob_data),
        .debug_input_fifo_empty(debug_input_fifo_empty),
        .o_enable_udp_tx(enable_udp_tx),
        .debug_input_fifo_full(),
        .leds()
    );

    // Monitor the internal state register for explicit verification
    assign r_System_State_monitor = uut.r_System_State;
    
    // =================================================================
    // 3. Clock Generation
    // =================================================================
    always #4.0 clk_udp    = ~clk_udp;    // 125 MHz (8ns period)
    always #2.5 clk_engine = ~clk_engine; // 200 MHz (5ns period) 

    // =================================================================
    // 4. Helper Tasks
    // =================================================================

    task wait_for_state;
        input [2:0] state; // The target FSM state value
        // input string state_name; <-- REMOVED
        
        // Internal variable to hold the state name for display
        reg [8*16:1] display_state_name; 
    
        begin
            // Map the state integer to a displayable name
            case (state)
                3'd0: display_state_name = "S0_FETCH_DATA";
                3'd1: display_state_name = "S0_1_SEND_ACK";
                3'd2: display_state_name = "S0_2_WAIT_DATA";
                3'd3: display_state_name = "S1_MARKET_BOT";
                3'd4: display_state_name = "S2_DUMP_CHECK";
                default: display_state_name = "UNKNOWN_STATE";
            endcase
    
            // Use the dynamically set display_state_name variable
            $display("[%0t] 🔄 TB: Waiting for FSM to enter state %s (%0d)...", $time, display_state_name, state);
            
            // Wait for the next clock edge to sample the state correctly
            @(posedge clk_engine); 
            
            // Loop until the monitor register matches the target state
            while (r_System_State_monitor !== state) begin
                @(posedge clk_engine);
            end
            
            $display("[%0t] ✅ TB: FSM reached state %s.", $time, display_state_name);
        end
    endtask
    
    task send_byte;
        input [7:0] data;
        input is_last;
        begin
            @(posedge clk_udp);
            rx_axis_tdata  <= data;
            rx_axis_tvalid <= 1;
            rx_axis_tlast  <= is_last;
        end
    endtask

    task send_udp_frame;
        input [23:0] opcode;
        input integer count;    
        input [11:0] market_index; 
        
        integer i, k;
        reg [7:0] current_byte;
        reg [31:0] current_order;
        begin
            $display("[%0t] ➡️ TB: Sending UDP Frame. Opcode=%h, Orders=%0d, Index=%0d", $time, opcode, count, market_index);

            // 1. HEADER (Bytes 0-41)
            for (i = 0; i < 42; i = i + 1) begin
                case(i)
                    12: current_byte = 8'h08; 13: current_byte = 8'h00;
                    23: current_byte = 8'h11;
                    30: current_byte = DEST_IP[31:24]; 31: current_byte = DEST_IP[23:16];
                    32: current_byte = DEST_IP[15:8];  33: current_byte = DEST_IP[7:0];
                    34: current_byte = SRC_PORT[15:8]; 35: current_byte = SRC_PORT[7:0];
                    default: current_byte = 8'hAA;    
                endcase
                send_byte(current_byte, 0);
            end

            // 2. OPCODE / INDEX (Bytes 42, 43, 44, 45) 
            send_byte(opcode[23:16], 0); // Byte 42

            if (opcode == OP_DUMP) begin
                send_byte(opcode[15:8],  0); // Byte 43
                send_byte(opcode[7:0], 0); // Byte 44: D0 (Dump)
            end else begin
                // Market Data format (xFEDxxx)
                send_byte({opcode[15:12], market_index[11:8]}, 0); // Byte 43: Index MSB (4 bits)
                send_byte(market_index[7:0], 0);           // Byte 44: Index LSB (8 bits)
            end
            
            i = 45;

            // 3. PAYLOAD (Orders) 
            if (count == 0) begin
                for (; i < 59; i = i + 1) send_byte(8'h00, 0);
                send_byte(8'h00, 1); // Last byte
            end else begin
                for (k = 0; k < count; k = k + 1) begin
                    current_order = order_batch[k];
                    // Send 32-bit Order (Big Endian)
                    send_byte(current_order[31:24], 0);
                    send_byte(current_order[23:16], 0);
                    send_byte(current_order[15:8],  0);
                    
                    if (k == count - 1) send_byte(current_order[7:0], 1);    
                    else                  send_byte(current_order[7:0], 0);
                end
            end

            // Cleanup
            @(posedge clk_udp);
            rx_axis_tvalid <= 0;
            rx_axis_tlast  <= 0;
            rx_axis_tdata  <= 0;
            repeat(100) @(posedge clk_udp);
        end
    endtask

    function [31:0] pack_order;
        input [15:0] price;
        input is_buy; // 1=Bid, 0=Ask
        input is_bot;
        input [13:0] qty;
        begin
            pack_order = {price, is_buy, is_bot, qty};
        end
    endfunction
    
    // =================================================================
    // 5. Monitors
    // =================================================================
    
    // Monitor Trade/Dump Output
    always @(posedge clk_engine) begin
        if (trade_valid) begin
            $display("[%0t] 💰 TRADE/DUMP OUTPUT: Price %0d, Qty %0d",    
                     $time, `PRICE(trade_info), `QTY(trade_info));
        end
    end
    
    // UDP Dump Monitor (Original code, kept for completeness)
//    initial begin
//        tx_fifo_tready = 1;    
//        forever begin
//            @(posedge clk_udp);
//            if (tx_fifo_tvalid) begin
//                $display("[%0t] DUMP OUTPUT (UDP): %h", $time, tx_fifo_tdata);
//            end
//        end
//    end
    // =================================================================
    // 6. Main Test Sequence
    // =================================================================
    initial begin
        $display("=======================================");
        $display("=== FSM SEQUENTIAL PROCESSING TEST ===");
        $display("=======================================");
        
        // Reset
        rst_udp = 1; rst_engine = 1;
        #100;
        rst_udp = 0; rst_engine = 0;
        #100;
        
        #9000;
        
        // Wait for system to enter initial fetch cycle
//        wait_for_state(S0_FETCH_DATA);
        
        
        // --- TEST 1: INJECT TWO ORDERS (Index 100) ---
        
        // FSM transitions: S0_FETCH_DATA -> S0_1_SEND_ACK -> S0_2_WAIT_DATA
        wait_for_state(S0_2_WAIT_DATA); 
        
        $display("\n[TEST 1] Injecting UDP burst (Index 100): 1 Buy (100@10), 1 Sell (110@5)");
        
        
                // 1. Buy Order (Bid): Price 100, Qty 10
        order_batch[0] = pack_order(100, 1, 0, 10); 
        // 2. Sell Order (Ask): Price 110, Qty 5
        order_batch[1] = pack_order(110, 0, 0, 5); 
        
        send_udp_frame(OP_MARKET, 2, 100); 
        
        // Wait for RX packet extraction and transition S0_2_WAIT_DATA -> S1_MARKET_BOT
        // Give time for CDC and extraction (1 packet = ~100 cycles @ 125MHz)
        #1; 
        wait_for_state(S1_MARKET_BOT);
        
        #5;
        if (uut.ob_inst.u_bid_heap.count == 1 && uut.ob_inst.u_ask_heap.count == 1) begin
             $display("\n[VERIFICATION] 🎉 SUCCESS! Book state is 1 Bid (100) and 1 Ask (110). Dump sequence verified.");
        end else begin
             $display("\n[VERIFICATION] ❌ FAIL! Expected 1 Bid/1 Ask. Actual Bids: %0d, Asks: %0d", uut.ob_inst.u_bid_heap.count, uut.ob_inst.u_ask_heap.count);
        end
        
        // 1c. Wait for S1 to finish the time delay (5000 cycles).
        // Since the engine aggressively pulls data (fifo_rd_en is !fifo_empty & !engine_busy), 
        // the two orders should be processed quickly (2 orders * ~10-15 cycles/order) long before 5000 cycles expire.
        $display("[%0t] ⏱️ In S1_MARKET_BOT. Waiting for %0d cycle timer delay...", $time, BOT_DELAY_CLKS);
//        repeat(BOT_DELAY_CLKS + 500) @(posedge clk_engine); // Wait 5500 cycles total
        
        
        
        
        // --- TEST 2: TRIGGER UDP DUMP ---
        
        // FSM is in S2_DUMP_CHECK. Send the Dump command.
        $display("\n[TEST 2] Triggering UDP Dump Command");
        send_udp_frame(OP_DUMP, 0, 0); 
        
        // 1d. FSM transitions: S1_MARKET_BOT -> S2_DUMP_CHECK
        wait_for_state(S2_DUMP_CHECK);
        
        // Wait for the Dump to complete. engine_busy will go high when the dump starts
        // and low when the dump is done. We check both status signals.
        $display("[%0t] ⏳ Waiting for Dump to complete...", $time);
        
        // Wait until engine is busy (dump starts)
//        repeat(50) @(posedge clk_engine);
        if (engine_busy) $display("[%0t] Dump sequence is active (engine_busy=1).", $time);
        
        // Wait until engine is idle again (dump finishes)
        while (engine_busy) begin
             @(posedge clk_engine);
        end
        $display("[%0t] ✅ Dump finished (engine_busy=0).", $time);

        // FSM moves back to S0_FETCH_DATA 
        wait_for_state(S0_FETCH_DATA);


        // FSM moves back to S0_FETCH_DATA 
        wait_for_state(S2_DUMP_CHECK);
        
        // FSM moves back to S0_FETCH_DATA 
        wait_for_state(S0_FETCH_DATA);


        // --- 3. VERIFICATION ---
        // Final check for book state.
        @(posedge clk_engine);
        // Assuming your 'order_book_top' module exposes the internal heap counts
        if (uut.ob_inst.u_bid_heap.count == 1 && uut.ob_inst.u_ask_heap.count == 1) begin
             $display("\n[VERIFICATION] 🎉 SUCCESS! Book state is 1 Bid (100) and 1 Ask (110). Dump sequence verified.");
        end else begin
             $display("\n[VERIFICATION] ❌ FAIL! Expected 1 Bid/1 Ask. Actual Bids: %0d, Asks: %0d", uut.ob_inst.u_bid_heap.count, uut.ob_inst.u_ask_heap.count);
        end


        $display("\n=== TEST COMPLETE ===");
        $finish;
    end

endmodule