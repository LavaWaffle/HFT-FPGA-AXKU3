`timescale 1ns / 1ps
`include "order_defines.v"
// Define macros locally in case order_defines.v is missing from this file scope
`ifndef PRICE
    `define PRICE(x) x[31:16]
    `define QTY(x)   x[13:0]
`endif

module tb_ob_trading_integration;

    // =================================================================
    // 1. Signals
    // =================================================================
    // UDP Domain (125 MHz)
    reg        clk_udp = 0;
    reg        rst_udp = 1;
    reg [7:0]  rx_axis_tdata = 0;
    reg        rx_axis_tvalid = 0;
    reg        rx_axis_tlast = 0;

    // Engine Domain (200 MHz)
    reg        clk_engine = 0;
    reg        rst_engine = 1;
    
    // Outputs
    wire [31:0] trade_info;
    wire        trade_valid;
    wire        engine_busy;
    wire [3:0]  leds;

    // =================================================================
    // 2. Instantiate the System Wrapper
    // =================================================================
    // This wrapper contains: Payload Extractor -> FIFO -> Your Real Order Book
    trading_system_top uut (
        .clk_udp(clk_udp),
        .rst_udp(rst_udp),
        .clk_engine(clk_engine),
        .rst_engine(rst_engine),
        .rx_axis_tdata(rx_axis_tdata),
        .rx_axis_tvalid(rx_axis_tvalid),
        .rx_axis_tlast(rx_axis_tlast),
        .trade_info(trade_info),
        .trade_valid(trade_valid),
        .engine_busy(engine_busy),
        .leds(leds)
    );

    // =================================================================
    // 3. Clock Generation
    // =================================================================
    always #4.0 clk_udp    = ~clk_udp;    // 125 MHz
    always #2.5 clk_engine = ~clk_engine; // 200 MHz

    // =================================================================
    // 4. Helper Tasks
    // =================================================================
    
    // Low-level UDP Byte sender
    task send_byte(input [7:0] data);
        begin
            @(posedge clk_udp);
            rx_axis_tvalid <= 1;
            rx_axis_tdata  <= data;
            rx_axis_tlast  <= 0;
        end
    endtask

    // Constructs the UDP packet (Header + Payload)
    task send_packet(input [31:0] order_data);
        integer i;
        begin
            // 1. Send Header Garbage (42 Bytes) - Simulates MAC/IP/UDP headers
            for (i=0; i<42; i=i+1) send_byte(8'hAA); 

            // 2. Send Payload (4 Bytes) - BIG ENDIAN (Network Order)
            // We send MSB first. The Wrapper will swap this back to Little Endian for your Order Book.
            send_byte(order_data[31:24]); 
            send_byte(order_data[23:16]); 
            send_byte(order_data[15:8]);  
            
            // Last Byte with TLAST
            @(posedge clk_udp);
            rx_axis_tdata  <= order_data[7:0]; 
            rx_axis_tlast  <= 1;
            
            @(posedge clk_udp);
            rx_axis_tvalid <= 0;
            rx_axis_tlast  <= 0;
            rx_axis_tdata  <= 0;
            
            // 3. Wait for FIFO Transit
            // It takes a few cycles for data to cross from UDP clock to Engine clock
            repeat(40) @(posedge clk_engine);
        end
    endtask

    // HIGH LEVEL: Submit Order via UDP
    task submit_order_udp;
        input is_buy;        // 1 bit
        input [15:0] price;  // 16 bits
        input [13:0] qty;    // 14 bits
        input is_bot;        // 1 bit
        reg [31:0] payload;
        begin
            // Pack the data: Price | Buy | Bot | Qty
            payload = {price, is_buy, is_bot, qty};
            
            // Send it over the "Network"
            send_packet(payload);
            
            // Wait logic: If engine becomes busy, wait for it to finish
            // Note: We access the internal signal via hierarchy if needed, 
            // or use the top-level 'engine_busy' output.
            while (engine_busy) @(posedge clk_engine);
        end
    endtask

    // PEEK TASK: Looks inside your Real Order Book
    task dump_book_tops;
        begin
            $display("--- BOOK STATUS (Peeking Internal State) ---");
            
            // HIERARCHICAL REFERENCE: uut (Wrapper) -> ob_inst (Order Book Instance) -> u_bid_heap
            if (uut.ob_inst.u_bid_heap.empty) 
                $display("BID: [EMPTY]");
            else 
                $display("BID: Top Price %0d, Qty %0d", 
                         `PRICE(uut.ob_inst.u_bid_heap.root_out), 
                         `QTY(uut.ob_inst.u_bid_heap.root_out));

            if (uut.ob_inst.u_ask_heap.empty) 
                $display("ASK: [EMPTY]");
            else 
                $display("ASK: Top Price %0d, Qty %0d", 
                         `PRICE(uut.ob_inst.u_ask_heap.root_out), 
                         `QTY(uut.ob_inst.u_ask_heap.root_out));
            $display("-------------------");
        end
    endtask

    // Monitor Trades from Top Level
    always @(posedge clk_engine) begin
        if (trade_valid) begin
            $display("[%0t] >>> TRADE EXECUTED: Price %0d, Qty %0d <<<", 
                     $time, `PRICE(trade_info), `QTY(trade_info));
        end
    end

    // =================================================================
    // 5. Main Test Sequence (Mirrors your standalone test)
    // =================================================================
    initial begin
        $display("=== SYSTEM INTEGRATION START ===");
        
        // Reset
        #100;
        rst_udp = 0;
        rst_engine = 0; // The wrapper inverts this for the order book
        #100;

        // ------------------------------------------------------------
        // SCENARIO 1: Populate the ASK Book (Sellers) via UDP
        // ------------------------------------------------------------
        $display("\n[TEST] Adding Sellers (Asks) via UDP...");
        submit_order_udp(0, 105, 50, 1); // Sell @ 105
        submit_order_udp(0, 102, 20, 1); // Sell @ 102
        submit_order_udp(0, 108, 10, 1); // Sell @ 108
        submit_order_udp(0, 100, 30, 1); // Sell @ 100 (Best)
        
        #500; // Allow time for processing
        dump_book_tops(); 
        // Expected: ASK Top = 100

        // ------------------------------------------------------------
        // SCENARIO 2: Populate the BID Book (Buyers) via UDP
        // ------------------------------------------------------------
        $display("\n[TEST] Adding Buyers (Bids) via UDP...");
        submit_order_udp(1, 90, 100, 1); 
        submit_order_udp(1, 95, 50,  1); // Buy @ 95 (Best)
        submit_order_udp(1, 92, 20,  1); 
        
        #500;
        dump_book_tops();
        // Expected: BID Top = 95

        // ------------------------------------------------------------
        // SCENARIO 3: NO MATCH
        // ------------------------------------------------------------
        $display("\n[TEST] Buy @ 98 (Should not match Ask @ 100)...");
        submit_order_udp(1, 98, 10, 1);
        
        #500;
        dump_book_tops();
        // Expected: BID Top = 98

        // ------------------------------------------------------------
        // SCENARIO 4: PARTIAL FILL
        // ------------------------------------------------------------
        $display("\n[TEST] Buy 10 @ 100 (Matches Ask @ 100)...");
        submit_order_udp(1, 100, 10, 1);
        
        #500;
        dump_book_tops();
        // Expected: ASK Top = 100, Qty 20 left.

        // ------------------------------------------------------------
        // SCENARIO 6: THE SWEEP (Massive Buy)
        // ------------------------------------------------------------
        $display("\n[TEST] Massive Buy 100 @ 110 (Sweeps 102, 105, 108)...");
        submit_order_udp(1, 110, 100, 1);
        
        #2000; // Needs more time for multiple trades
        dump_book_tops();
        
        $display("=== INTEGRATION TEST COMPLETE ===");
        $finish;
    end

endmodule