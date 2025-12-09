`timescale 1ns / 1ps
// Define macros locally for readability
`ifndef PRICE
    `define PRICE(x) x[31:16]
    `define IS_BUY(x) x[15]
    `define IS_BOT(x) x[14]
    `define QTY(x)    x[13:0]
    `define DUMP_SENTINEL 32'hFFFF_FFFF 
`endif
`define DUMP_SENTINEL 32'hFFFF_FFFF

`define CLKS_PER_BIT 1736
`define T_BIT_TIME_NS 8680 // 1736 * 5 ns

module tb_order_book_simple_udp;

    // =================================================================
    // 1. Signals & Constants
    // =================================================================
    reg         clk_udp = 0;
    reg         rst_udp = 1;
    reg [7:0]   rx_axis_tdata = 0;
    reg         rx_axis_tvalid = 0;
    reg         rx_axis_tlast = 0;

    reg         clk_engine = 0;
    reg         rst_engine = 1;

    // --- TOP LEVEL WIRES (Interface to UUT) ---
    wire [7:0]  tx_fifo_tdata;
    wire        tx_fifo_tvalid;
    reg         tx_fifo_tready = 0; // Control for FIFO drain
    wire [31:0] trade_info;
    wire        trade_valid;
    wire        engine_busy;
    wire [3:0]  leds;
    wire [31:0] debug_ob_data;

    // --- FSM CONTROL/DATA WIRES ---
    wire [11:0] o_tx_ack_index;
    wire o_tx_ack_start;
    wire i_tx_ack_done; // Driven by TB simulation
    wire enable_udp_tx; 
    
    // --- UART/DUMMY WIRES (Minimal required for port matching) ---
    reg [7:0] uart_rx_data_out_dummy = 0;
    reg uart_rx_data_valid_dummy = 0;
    wire [7:0] uart_tx_data_in_dummy;
    wire uart_tx_data_valid_dummy;
    reg uart_tx_ready_dummy = 1; 

    // Filter Constants
    localparam [31:0] DEST_IP  = {8'd192, 8'd168, 8'd1, 8'd50};    
    localparam [15:0] SRC_PORT = 16'd55555;                          
    localparam [23:0] OP_MARKET = 24'hFED000;
    localparam [23:0] OP_DUMP   = 24'hF0E0D0;
    
    // GLOBAL BUFFER
    reg [31:0] order_batch [0:63]; 
    reg [31:0] collected_dump_words [0:3];
    reg [2:0] collected_word_count = 0;


    // =================================================================
    // 2. Instantiate System Components
    // =================================================================
    
    // 2a. Trading System Top (The UUT)
    trading_system_top uut (
        .clk_udp(clk_udp),
        .rst_udp(rst_udp),
        .clk_engine(clk_engine),
        .rst_engine(rst_engine),
        .rx_axis_tdata(rx_axis_tdata),
        .rx_axis_tvalid(rx_axis_tvalid),
        .rx_axis_tlast(rx_axis_tlast),
        
        // --- UDP TX Output (Data/Dump traffic from FIFO) ---
        .tx_fifo_tdata(tx_fifo_tdata),
        .tx_fifo_tvalid(tx_fifo_tvalid),
        .tx_fifo_tready(tx_fifo_tready),
        
        // --- UART/DUMMY PORTS ---
        .uart_rx_data_out(uart_rx_data_out_dummy),
        .uart_rx_data_valid(uart_rx_data_valid_dummy),
        .uart_tx_data_in(uart_tx_data_in_dummy),
        .uart_tx_data_valid(uart_tx_data_valid_dummy),
        .uart_tx_ready(uart_tx_ready_dummy),
        
        // --- FSM CONTROL PORTS ---
        .o_enable_udp_tx(enable_udp_tx),
        .o_tx_ack_index(o_tx_ack_index),
        .o_tx_ack_start(o_tx_ack_start),
        .i_tx_ack_done(i_tx_ack_done),
        
        // --- Order Book Outputs ---
        .trade_info(trade_info),
        .trade_valid(trade_valid),
        .engine_busy(engine_busy),
        .leds(leds),
        .debug_ob_data(debug_ob_data),
        .debug_input_fifo_empty(),
        .debug_input_fifo_full()
    );

    // =================================================================
    // 3. Clock Generation
    // =================================================================
    always #4.0 clk_udp    = ~clk_udp;    // 125 MHz 
    always #2.5 clk_engine = ~clk_engine; // 200 MHz 

    // =================================================================
    // 3.5. SIMULATED ACK TRANSMISSION (Bypassing AXI stream flow)
    // This simulates the single-cycle ACK transaction completion.
    reg [1:0] ack_done_delay = 0;
    
    always @(posedge clk_udp) begin
        if (o_tx_ack_start) begin
            ack_done_delay <= 2'b10; // Start pulse delay (2 cycles @ clk_udp)
        end else if (ack_done_delay != 0) begin
            ack_done_delay <= ack_done_delay - 1;
        end
    end
    assign i_tx_ack_done = (ack_done_delay == 2'b01);//(ack_done_delay == 2'b01); // Pulse when delay finishes


    // =================================================================
    // 4. Helper Tasks
    // =================================================================
    
    // Low-level byte sender 
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

    // Send UDP Frame (Original code, kept for brevity)
    task send_udp_frame;
        input [23:0] opcode;
        input integer count;    
        
        integer i, k;
        reg [7:0] current_byte;
        reg [31:0] current_order;
        begin
            // 1. HEADER (Bytes 0-41)
            for (i = 0; i < 42; i = i + 1) begin
                // ... (omitted header logic)
                current_byte = 8'hAA; // Dummy value for simplicity
                send_byte(current_byte, 0);
            end

            // 2. OPCODE (Bytes 42-44)
            send_byte(opcode[23:16], 0);
            send_byte(opcode[15:8],  0);
            send_byte(opcode[7:0],   0);

            // 3. PAYLOAD (Orders)
            if (count == 0) begin
                send_byte(8'h00, 1); // Padding + TLAST for Empty payload
            end else begin
                for (k = 0; k < count; k = k + 1) begin
                    current_order = order_batch[k];
                    // Send 32-bit Order (Big Endian)
                    send_byte(current_order[31:24], 0);
                    send_byte(current_order[23:16], 0);
                    send_byte(current_order[15:8],  0);
                    
                    // Last byte TLAST check
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


    // Function to pack order (Original code, kept for completeness)
    function [31:0] pack_order;
        input [15:0] price;
        input is_buy; // 1=Bid, 0=Ask
        input is_bot;
        input [13:0] qty;
        begin
            pack_order = {price, is_buy, is_bot, qty};
        end
    endfunction
    
    task wait_for_idle_task;
        begin
            @(posedge clk_engine);
            wait(engine_busy == 0) @(posedge clk_engine);
        end
    endtask
    
    // Dump Read Task - Reads and verifies the full dump contents
    task read_dump_and_verify;
        input integer expected_count;
        integer k;
        reg [7:0] current_byte;
        reg [31:0] current_word;
        
        begin 
        
        $display("[%0t] DUMP READ: Starting to drain FIFO (Expecting %0d words + sentinel)...", $time, expected_count);

        // Assert TREADY high to drain the FIFO
        tx_fifo_tready = 1;
//        tb_tx_ready_control = 1;
        k = 0;
        
        while (k < expected_count * 4 + 4) begin // Total bytes = (4 * words) + 4 sentinel bytes
            @(posedge clk_udp);
            
            if (tx_fifo_tvalid) begin
                current_byte = tx_fifo_tdata;
                current_word = {current_byte, current_word[31:8]}; // Assuming Little Endian (first byte is LSB)

                if ((k % 4) == 3) begin // Every 4th byte completes a word
                    
                    if (current_word == `DUMP_SENTINEL) begin
                         $display("[%0t] DUMP READ: SENTINEL Word received (%h).", $time, current_word);
                         expected_count = expected_count + 1; // Count sentinel as a word for loop termination
                    end else begin
                         $display("[%0t] DUMP WORD %0d: %h", $time, (k / 4), current_word);
                         collected_dump_words[k/4] = current_word;
                    end
                    current_word = 0;
                end
                k = k + 1;
            end
        end

        tx_fifo_tready = 0;
        $display("[%0t] DUMP READ: Draining complete. Collected %0d words (including sentinel).", $time, k / 4);
        
        // FIX END: Insert end here
        end 
    endtask

    // Task to Peek into Heaps (Original code, kept for completeness)
    task check_heap_counts;
        input [9:0] expected_bids;
        input [9:0] expected_asks;
        begin
            $display("[%0t] CHECK: Bids=%0d, Asks=%0d", $time, 
                     uut.ob_inst.u_bid_heap.count, 
                     uut.ob_inst.u_ask_heap.count);
            
            if (uut.ob_inst.u_bid_heap.count == expected_bids && 
                uut.ob_inst.u_ask_heap.count == expected_asks) begin
                $display("     --> PASS");
            end else begin
                $display("     --> FAIL! Expected Bids: %0d, Asks: %0d", expected_bids, expected_asks);
            end
        end
    endtask

    // =================================================================
    // 5. Monitors (Simplified)
    // =================================================================
    
    // Trade Execution Monitor 
    always @(posedge clk_engine) begin
        if (trade_valid) begin
            $display("[%0t] >>> TRADE EXEC: Price %0d, Qty %0d <<<",    
                     $time, `PRICE(trade_info), `QTY(trade_info));
        end
    end
    
    // FSM State Monitor (Essential for debugging the FSM cycle)
    always @(posedge clk_engine) begin
        if (uut.r_System_State != uut.r_System_State_prev) begin // Assume a prev state reg is in uut for monitoring
            $display("[%0t] FSM TRANSITION: State changed from %0d to %0d.", $time, uut.r_System_State_prev, uut.r_System_State);
        end
    end


    // =================================================================
    // 6. Main Test Sequence
    // =================================================================
    initial begin
        $display("=== SIMPLE UDP BUY/SELL/DUMP TEST ===");
        
        // Reset
        rst_udp = 1; rst_engine = 1;
        #100;
        rst_udp = 0; rst_engine = 0;
        #100;

        #90000;
        
        // --- Simulate Initial FSM cycle (S0 -> S0.1 -> S0.2) ---
        $display("\n[INIT] Waiting for FSM to enter S0_2_WAIT_DATA...");
        repeat(100) @(posedge clk_engine); 
        
        // ----------------------------------------------------------------
        // STEP 1: ADD ORDERS
        // ----------------------------------------------------------------
        @(posedge clk_engine);
        // Wait until FSM is in the reception state (S0_2)
        wait(uut.r_System_State == 3'd2) @(posedge clk_engine); 
        $display("[%0t] STEP 1: FSM is in S0_2. Sending orders.", $time);

        // A. Add Sell (Ask)
        order_batch[0] = pack_order(105, 0, 0, 10); // Ask @ 105, Qty 10
        send_udp_frame(OP_MARKET, 1);
        #1000;
        
        // B. Add Buy (Bid)
        order_batch[0] = pack_order(90, 1, 0, 20); // Bid @ 90, Qty 20
        send_udp_frame(OP_MARKET, 1);
        #1000;

        // FSM should transition to S1_MARKET_BOT now, processing the 2 orders.
        $display("[%0t] STEP 1: Orders sent. Waiting for MarketBot processing.", $time);
        wait_for_idle_task; // Wait until engine_busy==0
        
        // ----------------------------------------------------------------
        // STEP 2: REQUEST DUMP (UDP)
        // ----------------------------------------------------------------
        @(posedge clk_engine);
        // We wait for the next FETCH cycle (S0_2)
        wait(uut.r_System_State == 3'd2) @(posedge clk_engine); 
        $display("[%0t] STEP 2: FSM is in S0_2. Requesting UDP Dump.", $time);

        send_udp_frame(OP_DUMP, 0); // Sends the F0E0D0 trigger
        #1000;
        
        // FSM should transition S1 -> S2 (Dump Check) -> S2 (Dump Active)
        $display("[%0t] STEP 2: Dump requested. Waiting for dump to complete...", $time);
        wait_for_idle_task; // Wait until dump (engine_busy) is complete
        
        // ----------------------------------------------------------------
        // STEP 3: READ DUMP OUTPUT
        // ----------------------------------------------------------------
        $display("[%0t] STEP 3: Starting FIFO drain.", $time);
        read_dump_and_verify(2); 
        
        // Final checks on the collected data
        if (collected_dump_words[0] == pack_order(90, 1, 0, 20) || 
            collected_dump_words[0] == pack_order(105, 0, 0, 10)) begin
            $display("[%0t] VERIFY: PASS - Dump contains expected Bid/Ask orders.", $time);
        end else begin
            $display("[%0t] VERIFY: FAIL - Dump content incorrect or empty.", $time);
        end
        
        $display("\n=== TEST COMPLETE ===");
        $finish;
    end
endmodule