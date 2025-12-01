`timescale 1ns / 1ps

// Define macros locally
`ifndef PRICE
    `define PRICE(x) x[31:16]
    `define IS_BUY(x) x[15]
    `define QTY(x)   x[13:0]
`endif

module tb_ob_trading_integration;

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

    // Filter Constants
    localparam [31:0] DEST_IP  = {8'd192, 8'd168, 8'd1, 8'd50}; 
    localparam [15:0] SRC_PORT = 16'd55555;                     
    
    localparam [23:0] OP_MARKET = 24'h102030;
    localparam [23:0] OP_DUMP   = 24'hF0E0D0;

    // GLOBAL BUFFER for Packet Generation
    // Increased size for stress testing
    reg [31:0] order_batch [0:31]; 

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
    // 4. Tasks
    // =================================================================
    
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

    // Task to send UDP Frame
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
                    12: current_byte = 8'h08;
                    13: current_byte = 8'h00;
                    23: current_byte = 8'h11;
                    30: current_byte = DEST_IP[31:24];
                    31: current_byte = DEST_IP[23:16];
                    32: current_byte = DEST_IP[15:8];
                    33: current_byte = DEST_IP[7:0];
                    34: current_byte = SRC_PORT[15:8];
                    35: current_byte = SRC_PORT[7:0];
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
                // Dump command (Empty payload), send padding + TLAST
                send_byte(8'h00, 1);
            end else begin
                for (k = 0; k < count; k = k + 1) begin
                    current_order = order_batch[k];
                    
                    // Send 32-bit Order
                    send_byte(current_order[31:24], 0);
                    send_byte(current_order[23:16], 0);
                    send_byte(current_order[15:8],  0);
                    
                    // Last byte check
                    if (k == count - 1) begin
                        send_byte(current_order[7:0], 1); // TLAST
                    end else begin
                        send_byte(current_order[7:0], 0);
                    end
                end
            end

            // Cleanup
            @(posedge clk_udp);
            rx_axis_tvalid <= 0;
            rx_axis_tlast  <= 0;
            rx_axis_tdata  <= 0;
            
            repeat(50) @(posedge clk_udp);
        end
    endtask

    // Helper function to pack bits
    function [31:0] pack_order;
        input [15:0] price;
        input is_buy;
        input is_bot;
        input [13:0] qty;
        begin
            pack_order = {price, is_buy, is_bot, qty};
        end
    endfunction

    // =================================================================
    // 5. Monitors
    // =================================================================
    
    // UDP TX Monitor (Dumps)
    initial begin
        tx_fifo_tready = 1; 
        forever begin
            @(posedge clk_udp);
            if (tx_fifo_tvalid) begin
                // Just printing raw bytes. In waveform, group these by 4.
                $display("[%0t] UDP TX OUT (Byte): %h", $time, tx_fifo_tdata);
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
        $display("=== HARDER ORDER BOOK STRESS TEST ===");
        
        // Reset
        rst_udp = 1; rst_engine = 1;
        #100;
        rst_udp = 0; rst_engine = 0;
        #100;

        // ----------------------------------------------------------------
        // PHASE 1: FRAGMENTATION (Complex Insertions)
        // ----------------------------------------------------------------
        // We will insert orders out of price sequence to test Heap Sifting.
        // We will also insert duplicate prices to test non-merging logic.
        $display("\n[TEST 1] Building Fragmentation (Sellers)...");
        
        // Order 1: Sell 10 @ 105 (Root)
        order_batch[0] = pack_order(105, 0, 0, 10);
        
        // Order 2: Sell 10 @ 102 (New Root, 105 pushes down)
        order_batch[1] = pack_order(102, 0, 0, 10);
        
        // Order 3: Sell 10 @ 100 (New Root, 102 pushes down)
        order_batch[2] = pack_order(100, 0, 0, 10);
        
        // Order 4: Sell 10 @ 102 (Duplicate Price! Should NOT merge because root is 100)
        order_batch[3] = pack_order(102, 0, 0, 10); 
        
        // Order 5: Sell 20 @ 100 (Matches Root! Should MERGE -> Root Qty becomes 30)
        order_batch[4] = pack_order(100, 0, 0, 20);
        
        // Order 6: Buy 55 @ 102 
        order_batch[5] = pack_order(102, 1, 0, 55);

        // Send all 5 orders in one burst
        send_udp_frame(OP_MARKET, 6);

        #10000; // Wait for heap to settle (5 insertions takes time)

        // ----------------------------------------------------------------
        // PHASE 2: VERIFY DUMP (Optimized Count)
        // ----------------------------------------------------------------
        // Expected State:
        // 1. Price 100, Qty 30 (Merged)
        // 2. Price 102, Qty 10
        // 3. Price 105, Qty 10
        // 4. Price 102, Qty 10 (Duplicate)
        // Total Count in Heap = 4 nodes.
        // Total Packets transmitted should be exactly 4 (plus headers).
        
        $display("\n[TEST 2] Dumping Book (Expect 4 Orders)...");
        send_udp_frame(OP_DUMP, 0);
        
        #3000;

        // ----------------------------------------------------------------
        // PHASE 3: THE SWEEP (Verify Priority Execution)
        // ----------------------------------------------------------------
        // We buy 45 units.
        // Should eat:
        // 1. 100 @ 30 (Best Price)
        // 2. 102 @ 10 (Next Best)
        // 3. 102 @  5 (From the duplicate node)
        // Remaining 5 on duplicate node stays in book. 105 stays in book.
        
        $display("\n[TEST 3] Sweeping Book (Buy 45 @ 110)...");
        
        order_batch[0] = pack_order(110, 1, 0, 45); 
        send_udp_frame(OP_MARKET, 1);
        
        #2000;
        
        // ----------------------------------------------------------------
        // PHASE 4: FINAL STATE CHECK
        // ----------------------------------------------------------------
        // Remaining Book should have:
        // 1. Price 102, Qty 5 (Remainder of duplicate)
        // 2. Price 105, Qty 10
        
        $display("\n[TEST 4] Final Dump (Expect 102@5 and 105@10)...");
        send_udp_frame(OP_DUMP, 0);

        #2000;
        $display("=== TEST COMPLETE ===");
        $finish;
    end

endmodule