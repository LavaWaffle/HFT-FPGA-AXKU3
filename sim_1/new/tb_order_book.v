`timescale 1ns / 1ps
`include "order_defines.v"

module tb_order_book;

    // =================================================================
    // 1. Signals and Constants
    // =================================================================
    reg clk;
    reg rst_n;

    // Inputs to DUT
    reg input_valid;
    reg [31:0] input_data; // {Price, ID, Qty}

    // Outputs from DUT
    wire engine_busy;
    wire [3:0] leds;
    wire trade_valid;
    wire [31:0] trade_info;

    // =================================================================
    // 2. Instantiate the Top Level
    // =================================================================
    order_book_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .input_valid(input_valid),
        .input_data(input_data),
        .engine_busy(engine_busy),
        .leds(leds),
        .trade_valid(trade_valid),
        .trade_info(trade_info)
    );

    // =================================================================
    // 3. Clock Generation
    // =================================================================
    always #5 clk = ~clk; // 100MHz Clock (10ns period)

    // =================================================================
    // 4. Helper Tasks (To make the test readable)
    // =================================================================
    
    // Task: Submit an Order
    task submit_order;
        input is_buy;        // 1 bit
        input [15:0] price;  // 16 bits
        input [13:0] qty;    // 14 bits (Shrunk from 15)
        input is_bot;        // 1 bit
        begin
            // Wait for engine to be ready
            wait(engine_busy == 0);
            @(posedge clk); 

            // Construct Data Packet
            input_valid = 1;
            // Price [31:16] | Side [15] | ID [14] | Qty [13:0]
            input_data = {price, is_buy, is_bot, qty};
            @(posedge clk);
            input_valid = 0;
            
            // Wait for engine to acknowledge busy
            wait(engine_busy == 1);
            // Wait for engine to finish
            wait(engine_busy == 0);
            @(posedge clk);
            #10; // Small buffer
        end
    endtask

    // Task: Display Book State (Peeking into internals)
    task dump_book_tops;
        begin
            $display("--- BOOK STATUS ---");
            if (dut.u_bid_heap.empty) 
                $display("BID: [EMPTY]");
            else 
                $display("BID: Top Price %0d, Qty %0d", 
                         `PRICE(dut.u_bid_heap.root_out), 
                         `QTY(dut.u_bid_heap.root_out));

            if (dut.u_ask_heap.empty) 
                $display("ASK: [EMPTY]");
            else 
                $display("ASK: Top Price %0d, Qty %0d", 
                         `PRICE(dut.u_ask_heap.root_out), 
                         `QTY(dut.u_ask_heap.root_out));
            $display("-------------------");
        end
    endtask

    // Monitor Trades
    always @(posedge clk) begin
        if (trade_valid) begin
            $display("[%0t] TRADE EXEC: Price %0d, Qty %0d", 
                     $time, `PRICE(trade_info), `QTY(trade_info));
        end
    end

    // =================================================================
    // 5. Main Test Sequence
    // =================================================================
    initial begin
        // Init
        clk = 0;
        rst_n = 0;
        input_valid = 0;
        input_data = 0;

        $display("=== SIMULATION START ===");
        
        // Reset
        #50 rst_n = 1;
        #20;

        // ------------------------------------------------------------
        // SCENARIO 1: Populate the ASK Book (Sellers)
        // ------------------------------------------------------------
        $display("\n[TEST] Adding Sellers (Asks)...");
        // We add them OUT OF ORDER to test Min-Heap "Bubble Up"
        submit_order(0, 105, 50, 1); // Sell @ 105
        submit_order(0, 102, 20, 1); // Sell @ 102 (New Best)
        submit_order(0, 108, 10, 1); // Sell @ 108
        submit_order(0, 100, 30, 1); // Sell @ 100 (New Best)
        
        dump_book_tops();
        // Expected: ASK Top = 100, Qty 30

        // ------------------------------------------------------------
        // SCENARIO 2: Populate the BID Book (Buyers)
        // ------------------------------------------------------------
        $display("\n[TEST] Adding Buyers (Bids)...");
        // Out of order to test Max-Heap
        submit_order(1, 90, 100, 1); // Buy @ 90
        submit_order(1, 95, 50,  1); // Buy @ 95 (New Best)
        submit_order(1, 92, 20,  1); // Buy @ 92
        
        dump_book_tops();
        // Expected: BID Top = 95, Qty 50

        // ------------------------------------------------------------
        // SCENARIO 3: NO MATCH (Crossing Spread Fail)
        // ------------------------------------------------------------
        $display("\n[TEST] Buy @ 98 (Should not match Ask @ 100)...");
        submit_order(1, 98, 10, 1);
        
        dump_book_tops();
        // Expected: BID Top = 98 (New Best Bid), No Trade

        // ------------------------------------------------------------
        // SCENARIO 4: PARTIAL FILL (Update Logic)
        // ------------------------------------------------------------
        $display("\n[TEST] Buy 10 @ 100 (Matches Ask @ 100, Qty 30)...");
        // Ask has 30. We buy 10. Ask should remain with 20.
        submit_order(1, 100, 10, 1);
        
        dump_book_tops();
        // Expected: ASK Top = 100, Qty 20. Trade generated.

        // ------------------------------------------------------------
        // SCENARIO 5: EXACT FILL (Pop Logic)
        // ------------------------------------------------------------
        $display("\n[TEST] Buy 20 @ 100 (Matches remainder of Ask @ 100)...");
        // Ask has 20 left. We buy 20. Ask @ 100 should die.
        // Next Best Ask should be 102.
        submit_order(1, 100, 20, 1);
        
        dump_book_tops();
        // Expected: ASK Top = 102. Trade generated.

        // ------------------------------------------------------------
        // SCENARIO 6: THE SWEEP (Multi-Level Pop + Rest)
        // ------------------------------------------------------------
        $display("\n[TEST] Massive Buy 100 @ 110 (Sweeps 102, 105, 108, Rests)...");
        // Current Asks: 102 (Qty 20), 105 (Qty 50), 108 (Qty 10)
        // Total Liquidity = 80.
        // Incoming Buy = 100.
        // Expect: 3 Trades. 20 Remainder rests at Bid @ 110.
        
        submit_order(1, 110, 100, 1);
        
        dump_book_tops();
        // Expected: ASK Empty. BID Top = 110 (Qty 20).

        // ------------------------------------------------------------
        // SCENARIO 7: Checking LEDs (Full/Empty Flags)
        // ------------------------------------------------------------
        $display("\n[TEST] Checking Flags...");
        if (dut.u_ask_heap.empty) $display("SUCCESS: Ask Heap is Empty.");
        else $display("FAIL: Ask Heap should be empty.");
        
        $display("=== SIMULATION END ===");
        $finish;
    end

endmodule