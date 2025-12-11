`timescale 1ns / 1ps

// Macros for decoding (Must match your system)
`ifndef PRICE
    `define PRICE(x) x[31:16]
    `define IS_BUY(x) x[15]
    `define IS_BOT(x) x[14]
    `define QTY(x)    x[13:0]
`endif

module tb_bot_and_book;

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
    
    // --- BOT CONTROL ---
    reg         toggle_bot_enable = 0; // Simulate button press

    // --- LOW-LEVEL UART PINS ---
    reg  uart_rx_i = 1'b1;          // Raw asynchronous input pin
    wire uart_tx_o;                 // Raw asynchronous output pin
    
    // --- UDP TX Output Wires ---
    wire [7:0]  tx_fifo_tdata;
    wire        tx_fifo_tvalid;
    reg         tx_fifo_tready = 0;
    
    // --- UART TX Output Wires
    wire [7:0] uart_tx_data_in;
    wire       uart_tx_data_valid;
    wire       uart_tx_ready;

    // --- Trading System Debug Wires ---
    wire [31:0] trade_info;
    wire        trade_valid;
    wire        engine_busy;
    wire [3:0]  leds;
    wire [31:0] debug_ob_data;
    wire debug_input_fifo_empty;
    wire debug_input_fifo_full;

    // Filter Constants
    localparam [31:0] DEST_IP  = {8'd192, 8'd168, 8'd1, 8'd50};     
    localparam [15:0] SRC_PORT = 16'd55555;                         
    
    localparam [23:0] OP_MARKET = 24'h102030;
    localparam [23:0] OP_DUMP   = 24'hF0E0D0;
    
    // GLOBAL BUFFER for Packet Generation
    reg [31:0] order_batch [0:63]; 

    // =================================================================
    // 2. Instantiate System Components
    // =================================================================

    // 2a. UART Receiver Instance (Dummy - just to satisfy port)
    // We are focusing on Bot/UDP interaction here.
    wire [7:0] uart_rx_data_out_synced; 
    wire uart_rx_data_valid_synced;     
    uart_receiver uart_rx_inst (
        .i_Clock     (clk_engine),
        .i_Rx_Serial (uart_rx_i),           
        .o_Rx_DV     (uart_rx_data_valid_synced),
        .o_Rx_Byte   (uart_rx_data_out_synced)
    );

    // 2b. Trading System Top (The core logic wrapper)
    trading_system_top uut (
        .clk_udp(clk_udp),
        .rst_udp(rst_udp),
        .clk_engine(clk_engine),
        .rst_engine(rst_engine),
        
        .toggle_bot_enable(toggle_bot_enable), // <--- BOT TRIGGER

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
        .debug_ob_data(debug_ob_data),
        
        .uart_rx_data_out(uart_rx_data_out_synced),
        .uart_rx_data_valid(uart_rx_data_valid_synced),
        
        .uart_tx_data_in(uart_tx_data_in),
        .uart_tx_data_valid(uart_tx_data_valid),
        .uart_tx_ready(uart_tx_ready),
        
        .debug_input_fifo_empty(debug_input_fifo_empty),
        .debug_input_fifo_full(debug_input_fifo_full)
    );

    // =================================================================
    // 3. Clock Generation
    // =================================================================
    always #4.0 clk_udp    = ~clk_udp;    // 125 MHz 
    always #2.5 clk_engine = ~clk_engine; // 200 MHz 

    // =================================================================
    // 4. Helper Tasks
    // =================================================================
    
    // Low-level UDP byte sender
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

    // Send UDP Frame
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

    // Task to Peek into Heaps
    task check_heap_counts;
        input [9:0] expected_bids;
        input [9:0] expected_asks;
        begin
            $display("[%0t] CHECK: Bids=%0d, Asks=%0d", $time, 
                     uut.ob_inst.u_bid_heap.count, 
                     uut.ob_inst.u_ask_heap.count);
            
            if (uut.ob_inst.u_bid_heap.count == expected_bids && 
                uut.ob_inst.u_ask_heap.count == expected_asks) begin
                $display("      --> PASS");
            end else begin
                $display("      --> FAIL! Expected Bids: %0d, Asks: %0d", expected_bids, expected_asks);
            end
        end
    endtask

    // =================================================================
    // 5. Monitors
    // =================================================================
    
    // Trade Execution Monitor
    always @(posedge clk_engine) begin
        if (trade_valid) begin
            $display("[%0t] >>> ENGINE OUTPUT: Price %0d, Qty %0d, IsBuy %0d, IsBot %0d <<<",     
                     $time, `PRICE(trade_info), `QTY(trade_info), `IS_BUY(trade_info), `IS_BOT(trade_info));
        end
    end
    
    // Bot FIFO Monitor
    always @(posedge clk_engine) begin
        if (uut.bot_fifo_read_en) begin
             $display("[%0t] [BOT] Inserting Order into Engine: %h", $time, uut.bot_out_order);
        end
    end

    // =================================================================
    // 6. Main Test Sequence
    // =================================================================
    initial begin
        $display("=== BOT vs BOOK TEST ===");
        
        // Reset
        rst_udp = 1; rst_engine = 1;
        toggle_bot_enable = 0;
        #100;
        rst_udp = 0; rst_engine = 0;
        #100;
        
        #99999;
        
        // ----------------------------------------------------------------
        // TEST 1: SETUP MARKET DATA (No Bot yet)
        // ----------------------------------------------------------------
        $display("\n[TEST 1] Seeding Market Data...");
        
        // 1. Add a MARKET Sell (Ask) @ 105 -> Ask Heap
        // 102030 Packet with 1 order
        order_batch[0] = pack_order(105, 0, 0, 10);     
        send_udp_frame(OP_MARKET, 1);
        #2000;
        
        // 2. Add a MARKET Buy (Bid) @ 90 -> Bid Heap
        order_batch[0] = pack_order(90, 1, 0, 10);     
        send_udp_frame(OP_MARKET, 1);
        #2000;
        
        check_heap_counts(1, 1); // Bids: 1 (90), Asks: 1 (105)

        // ----------------------------------------------------------------
        // TEST 2: ENABLE BOT (Front Running)
        // ----------------------------------------------------------------
        $display("\n[TEST 2] Enabling Bot...");
        
        // Simulate Button Press to Enable Bot
        @(posedge clk_engine);
        toggle_bot_enable = 1;
        @(posedge clk_engine);
        toggle_bot_enable = 0;
        
        // Wait for Bot to react
        // Bot logic:
        // 1. Detects Best Bid (90, Not Bot). Places Bid @ 91.
        // 2. Detects Best Ask (105, Not Bot). Places Ask @ 104.
        
        // Give it time to cycle through states and FIFO
        #5000;
        
       // @(posedge clk_engine);
        //toggle_bot_enable = 1;
        //@(posedge clk_engine);
        //toggle_bot_enable = 0;
        
        $display("Checking Bot Results...");
        // Expected: Bids: 2 (90, 91), Asks: 2 (105, 104)
        check_heap_counts(2, 2); 
        
        // Verify Roots (Dot Syntax magic)
        if (`PRICE(uut.ob_inst.bid_root) == 91 && `IS_BOT(uut.ob_inst.bid_root))
            $display("PASS: Bot is Best Bid @ 91");
        else
            $display("FAIL: Best Bid is %0d (Expected 91)", `PRICE(uut.ob_inst.bid_root));

        if (`PRICE(uut.ob_inst.ask_root) == 104 && `IS_BOT(uut.ob_inst.ask_root))
            $display("PASS: Bot is Best Ask @ 104");
        else
            $display("FAIL: Best Ask is %0d (Expected 104)", `PRICE(uut.ob_inst.ask_root));

        // ----------------------------------------------------------------
        // TEST 3: MARKET FIGHTS BACK
        // ----------------------------------------------------------------
        $display("\n[TEST 3] Market Places Better Orders...");
        
        // Market places Bid @ 92 (Beating Bot's 91)
        order_batch[0] = pack_order(92, 1, 0, 10);     
        send_udp_frame(OP_MARKET, 1);
        #2000;
        
        // Simulate Button Press to Enable Bot
//        @(posedge clk_engine);
//        toggle_bot_enable = 1;
//        @(posedge clk_engine);
//        toggle_bot_enable = 0;
        
        // Wait for Bot to react
        // Bot logic:
        // 1. Detects Best Bid (90, Not Bot). Places Bid @ 91.
        // 2. Detects Best Ask (105, Not Bot). Places Ask @ 104.
        
        // Give it time to cycle through states and FIFO
        #5000;
        
//        @(posedge clk_engine);
//        toggle_bot_enable = 1;
//        @(posedge clk_engine);
        
        // Check if Bot reacted
        // Bot should see 92 (Not Bot), and place 93.
        #5000;
        
        if (`PRICE(uut.ob_inst.bid_root) == 93 && `IS_BOT(uut.ob_inst.bid_root))
            $display("PASS: Bot Front-Ran the new Market Bid (Market=92, Bot=93)");
        else
            $display("FAIL: Bot did not react properly. Best: %0d", `PRICE(uut.ob_inst.bid_root));

        // ----------------------------------------------------------------
        // TEST 4: DUMP STABILITY
        // ----------------------------------------------------------------
        $display("\n[TEST 4] Requesting Dump...");
        
        // While dump is active, Bot should NOT be able to insert orders.
        // But since we are front-running top of book, and dumping freezes book, 
        // bot signals should be ignored/held.
        
        tx_fifo_tready = 1; // Enable reading the dump
        send_udp_frame(OP_DUMP, 0);
        
        #50000; // Wait for dump to clear

        $display("\n=== TEST COMPLETE ===");
        $finish;
    end

endmodule