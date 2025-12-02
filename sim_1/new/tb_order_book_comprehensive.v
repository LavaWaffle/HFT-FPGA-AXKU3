`timescale 1ns / 1ps

// Define macros locally for readability
`ifndef PRICE
    `define PRICE(x) x[31:16]
    `define IS_BUY(x) x[15]
    `define IS_BOT(x) x[14]
    `define QTY(x)   x[13:0]
`endif

module tb_order_book_comprehensive;

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
    
    wire [7:0]  tx_fifo_tdata;
    wire        tx_fifo_tvalid;
    reg         tx_fifo_tready = 0;

    wire [31:0] trade_info;
    wire        trade_valid;
    wire        engine_busy;
    wire [3:0]  leds;
    wire [31:0] debug_ob_data;

    // Filter Constants (Must match your UDP Extractor settings)
    localparam [31:0] DEST_IP  = {8'd192, 8'd168, 8'd1, 8'd50}; 
    localparam [15:0] SRC_PORT = 16'd55555;                     
    
    localparam [23:0] OP_MARKET = 24'h102030;
    localparam [23:0] OP_DUMP   = 24'hF0E0D0;

    // GLOBAL BUFFER for Packet Generation
    // Large buffer to handle stress test scenarios
    reg [31:0] order_batch [0:63]; 

    // =================================================================
    // 2. Instantiate System
    // =================================================================
    trading_system_top uut (
        .clk_udp(clk_udp),
        .rst_udp(rst_udp),
        .clk_engine(clk_engine),
        .rst_engine(rst_engine),
        .rx_axis_tdata(rx_axis_tdata),
        .rx_axis_tvalid(rx_axis_tvalid),
        .rx_axis_tlast(rx_axis_tlast),
        .tx_fifo_tdata(tx_fifo_tdata),
        .tx_fifo_tvalid(tx_fifo_tvalid),
        .tx_fifo_tready(tx_fifo_tready),
        .trade_info(trade_info),
        .trade_valid(trade_valid),
        .engine_busy(engine_busy),
        .leds(leds),
        .debug_ob_data(debug_ob_data)
    );

    // =================================================================
    // 3. Clock Generation
    // =================================================================
    always #4.0 clk_udp    = ~clk_udp;    // 125 MHz 
    always #2.5 clk_engine = ~clk_engine; // 200 MHz 

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

    // Send UDP Frame (Header + Opcode + Payload)
    task send_udp_frame;
        input [23:0] opcode;
        input integer count; 
        
        integer i, k;
        reg [7:0] current_byte;
        reg [31:0] current_order;
        begin
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
                    else                send_byte(current_order[7:0], 0);
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

    // Function to pack order
    function [31:0] pack_order;
        input [15:0] price;
        input is_buy; // 1=Bid, 0=Ask
        input is_bot;
        input [13:0] qty;
        begin
            pack_order = {price, is_buy, is_bot, qty};
        end
    endfunction

    // Task to Peek into Heaps (Verifies correct storage)
    task check_heap_counts;
        input [9:0] expected_bids;
        input [9:0] expected_asks;
        begin
            $display("[%0t] CHECK: Bids=%0d, Asks=%0d", $time, 
                     uut.ob_inst.u_bid_heap.count, 
                     uut.ob_inst.u_ask_heap.count);
            
            if (uut.ob_inst.u_bid_heap.count == expected_bids && 
                uut.ob_inst.u_ask_heap.count == expected_asks) begin
                $display("    --> PASS");
            end else begin
                $display("    --> FAIL! Expected Bids: %0d, Asks: %0d", expected_bids, expected_asks);
            end
        end
    endtask

    // =================================================================
    // 5. Monitors
    // =================================================================
    
    // UDP Dump Monitor
    initial begin
        tx_fifo_tready = 1; 
        forever begin
            @(posedge clk_udp);
            if (tx_fifo_tvalid) begin
                // Grouping visually helpful, but raw byte is fine
                $display("[%0t] DUMP OUTPUT BYTE: %h", $time, tx_fifo_tdata);
            end
        end
    end

    // Trade Execution Monitor
    always @(posedge clk_engine) begin
        if (trade_valid) begin
            $display("[%0t] >>> TRADE EXEC: Price %0d, Qty %0d <<<", 
                     $time, `PRICE(trade_info), `QTY(trade_info));
        end
    end

    // =================================================================
    // 6. Main Stress Test Sequence
    // =================================================================
    initial begin
        $display("=== COMPREHENSIVE ORDER BOOK TEST ===");
        
        // Reset
        rst_udp = 1; rst_engine = 1;
        #100;
        rst_udp = 0; rst_engine = 0;
        #100;
        #50000;

        // ----------------------------------------------------------------
        // TEST 1: ROUTING & BASIC POPULATION
        // Verify Bids go to Bid Heap, Asks go to Ask Heap
        // ----------------------------------------------------------------
        $display("\n[TEST 1] Routing Verification...");
        
        // 1. Add a Sell (Ask) -> Ask Heap
        order_batch[0] = pack_order(105, 0, 0, 10); 
        send_udp_frame(OP_MARKET, 1);
        #1000;
        check_heap_counts(0, 1); // Bids: 0, Asks: 1

        // 2. Add a Buy (Bid) -> Bid Heap
        order_batch[0] = pack_order(90, 1, 0, 10); 
        send_udp_frame(OP_MARKET, 1);
        #1000;
        check_heap_counts(1, 1); // Bids: 1, Asks: 1

        $display("\n[TEST 1.5] Dumping Book...");
        send_udp_frame(OP_DUMP, 0);
        #3000;

        // ----------------------------------------------------------------
        // TEST 2: SORTING & PRIORITY (The Jumbled Insertion)
        // Insert orders out of order, check if Heap sorts them
        // ----------------------------------------------------------------
        $display("\n[TEST 2] Sorting & Priority Check...");
        
        // Current Ask is 105.
        // Insert 100 (Better), 102 (Middle), 108 (Worse)
        order_batch[0] = pack_order(100, 0, 0, 10);
        order_batch[1] = pack_order(102, 0, 0, 10);
        order_batch[2] = pack_order(108, 0, 0, 10);
        
        send_udp_frame(OP_MARKET, 3);
        #2000;
        
        // Check Internal Root (Should be 100)
        if (`PRICE(uut.ob_inst.u_ask_heap.root_out) == 100) 
            $display("    --> PASS: Ask Root is 100 (Min Heap Correct)");
        else 
            $display("    --> FAIL: Ask Root is %0d (Expected 100)", `PRICE(uut.ob_inst.u_ask_heap.root_out));

        $display("\n[TEST 2.5] Dumping Book...");
        send_udp_frame(OP_DUMP, 0);
        #3000;

        // ----------------------------------------------------------------
        // TEST 3: DUPLICATE PRICE HANDLING (Non-Root)
        // Insert Duplicate 102. Root is 100, so 102 is deeper.
        // Should NOT merge. Should create new node.
        // ----------------------------------------------------------------
        $display("\n[TEST 3] Duplicate Price Injection...");
        
        order_batch[0] = pack_order(102, 0, 0, 5);
        send_udp_frame(OP_MARKET, 1);
        #1000;
        
        // Total Asks: 105, 100, 102, 108 + new 102 = 5 Orders
        check_heap_counts(1, 5);

         $display("\n[TEST 3.5] Dumping Book...");
        send_udp_frame(OP_DUMP, 0);
        #3000;

        // ----------------------------------------------------------------
        // TEST 4: DUMP VERIFICATION
        // Verify all orders come out. (Order might vary slightly for equal prices)
        // ----------------------------------------------------------------
        $display("\n[TEST 4] Dumping Book...");
        send_udp_frame(OP_DUMP, 0);
        #3000;

        // ----------------------------------------------------------------
        // TEST 5: THE BIG SWEEP (Execution Logic)
        // Buy 45 units.
        // Expected Execution Path:
        // 1. Ask 100 @ 10 -> Fully Filled
        // 2. Ask 102 @ 10 -> Fully Filled
        // 3. Ask 102 @  5 -> Fully Filled (Duplicate)
        // 4. Ask 105 @ 10 -> Fully Filled
        // Total filled: 35.
        // Remainder: 10 units left over.
        // Since it's a Buy, remainder should post to Bid book @ 110 (assuming we send limit 110)
        // ----------------------------------------------------------------
        $display("\n[TEST 5] The Sweep (Buy 55 @ 110)...");
        
        order_batch[0] = pack_order(110, 1, 0, 55);
        send_udp_frame(OP_MARKET, 1);
        
        #3000;
        
         $display("\n[TEST 6] (Sell 5 @ 60)...");
        
        order_batch[0] = pack_order(110, 0, 1, 15);
        send_udp_frame(OP_MARKET, 1);
        
        #3000;
        
        
        // Check Final State
        // Asks remaining: Only 108 @ 10.
        // Bids remaining: 90 @ 10 (original) + 110 @ 10 (remainder of sweep).
        // Note: Bid 110 should be at Root.
        
        $display("--- POST SWEEP STATUS ---");
        check_heap_counts(2, 1); // Expect 2 Bids, 1 Ask
        
        if (`PRICE(uut.ob_inst.u_bid_heap.root_out) == 110) 
            $display("    --> PASS: Bid Root is 110 (Sweep Remainder Posted)");
        else 
            $display("    --> FAIL: Bid Root is %0d (Expected 110)", `PRICE(uut.ob_inst.u_bid_heap.root_out));

    $display("---DUMP POST SWEEP  ---");

         send_udp_frame(OP_DUMP, 0);
        
        #3000;

        $display("\n=== TEST COMPLETE ===");
        $finish;
    end

endmodule