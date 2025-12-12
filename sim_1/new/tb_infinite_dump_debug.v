`timescale 1ns / 1ps

`ifndef PRICE
    `define PRICE(x) x[31:16]
    `define IS_BUY(x) x[15]
    `define IS_BOT(x) x[14]
    `define QTY(x)    x[13:0]
`endif

module tb_infinite_dump_debug;

    // --- CLOCKS ---
    reg clk_udp = 0;    // 125 MHz
    reg clk_engine = 0; // 200 MHz
    always #4.0 clk_udp = ~clk_udp;
    always #2.5 clk_engine = ~clk_engine;

    // --- SIGNALS ---
    reg rst_udp = 1;
    reg rst_engine = 1;
    reg toggle_bot_enable = 0;

    // UDP RX
    reg [7:0] rx_axis_tdata = 0;
    reg       rx_axis_tvalid = 0;
    reg       rx_axis_tlast = 0;

    // Outputs
    wire [7:0] tx_fifo_tdata;
    wire       tx_fifo_tvalid;
    reg        tx_fifo_tready = 1; // Always accept dumps for stress testing
    
    // Debug
    wire engine_busy;
    wire [31:0] trade_info;
    wire trade_valid;

    // --- INSTANCE ---
    trading_system_top dut (
        .clk_udp(clk_udp), .rst_udp(rst_udp),
        .clk_engine(clk_engine), .rst_engine(rst_engine),
        .toggle_bot_enable(toggle_bot_enable),
        .rx_axis_tdata(rx_axis_tdata),
        .rx_axis_tvalid(rx_axis_tvalid),
        .rx_axis_tlast(rx_axis_tlast),
        // Tie off UART to 1 (IDLE) to simulate a "good" cable, 
        // or toggle it to simulate noise if you want to test robustness.
        .uart_rx_data_out(8'h00), 
        .uart_rx_data_valid(1'b0),
        .tx_fifo_tdata(tx_fifo_tdata),
        .tx_fifo_tvalid(tx_fifo_tvalid),
        .tx_fifo_tready(tx_fifo_tready),
        .engine_busy(engine_busy),
        .trade_info(trade_info),
        .trade_valid(trade_valid),
        .uart_tx_data_in(), .uart_tx_data_valid(), .uart_tx_ready(1'b1),
        .leds(), .debug_ob_data(), .debug_input_fifo_empty(), .debug_input_fifo_full()
    );

    // --- CONSTANTS ---
    localparam [31:0] DEST_IP  = {8'd192, 8'd168, 8'd1, 8'd50};      
    localparam [15:0] SRC_PORT = 16'd55555;    
    localparam [23:0] OP_MARKET = 24'h102030;
    localparam [23:0] OP_DUMP   = 24'hF0E0D0;

    reg [31:0] order_batch [0:10];

    // --- TASKS ---
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

    function [31:0] pack_order;
        input [15:0] p; input b; input bot; input [13:0] q;
        pack_order = {p, b, bot, q};
    endfunction

    // Trade Execution Monitor
    always @(posedge clk_engine) begin
        if (trade_valid) begin
            $display("[%0t] >>> ENGINE OUTPUT: Price %0d, Qty %0d, IsBuy %0d, IsBot %0d <<<",     
                     $time, `PRICE(trade_info), `QTY(trade_info), `IS_BUY(trade_info), `IS_BOT(trade_info));
        end
    end

    // Bot FIFO Monitor
    always @(posedge clk_engine) begin
        if (dut.bot_fifo_read_en) begin
             $display("[%0t] [BOT] Inserting Order into Engine: %h", $time, dut.bot_out_order);
        end
    end


    // --- MAIN TEST ---
    initial begin
        $display("=== SIMULATION START ===");
        rst_udp = 1; rst_engine = 1;
        #100;
        rst_udp = 0; rst_engine = 0;
        #100;
        
        #9000;

        // Enable Bot
        @(posedge clk_engine); toggle_bot_enable = 1;
        @(posedge clk_engine); toggle_bot_enable = 0;

        // --- STEP 0: SEED ---
        $display("[STEP 0] Seeding Market...");
        // BUY 96 19
        order_batch[0] = pack_order(96, 1, 0, 19); 
        // BUY 97 39
        order_batch[1] = pack_order(97, 1, 0, 39);
        // BUY 96 11
        order_batch[2] = pack_order(96, 1, 0, 11);
        // BUY 98 22
        order_batch[3] = pack_order(98, 1, 0, 22);
        // SELL 104 39
        order_batch[4] = pack_order(104, 0, 0, 39);
        // SELL 104 11
        order_batch[5] = pack_order(104, 0, 0, 11);
        
        send_udp_frame(OP_MARKET, 6);
        
        #22000; // WAIT 2.0 (scaled)
        $display("[STEP 0] Dumping...");
        send_udp_frame(OP_DUMP, 0);
        #52000; // Wait for dump to clear

        // --- STEP 1: Price 100.00 ---
        $display("[STEP 1] Price Moves to 100...");
        // BUY 98 18
        order_batch[0] = pack_order(98, 1, 0, 18);
        // BUY 100 45
        order_batch[1] = pack_order(100, 1, 0, 45);
        // BUY 99 21
        order_batch[2] = pack_order(99, 1, 0, 21);
        // BUY 99 28
        order_batch[3] = pack_order(99, 1, 0, 28);
        // SELL 105 19
        order_batch[4] = pack_order(105, 0, 0, 19);
        // SELL 104 26
        order_batch[5] = pack_order(104, 0, 0, 26);

        send_udp_frame(OP_MARKET, 6);

        #50000; // WAIT 2.70
        $display("[STEP 1] Dumping...");
        send_udp_frame(OP_DUMP, 0);
        #150000;

        // --- STEP 2: Price 101.00 ---
        $display("[STEP 2] Price Moves to 101...");
        // BUY 99 11
        order_batch[0] = pack_order(99, 1, 0, 11);
        // BUY 95 10
        order_batch[1] = pack_order(95, 1, 0, 10);
        // BUY 95 49
        order_batch[2] = pack_order(95, 1, 0, 49);
        // SELL 101 38
        order_batch[3] = pack_order(101, 0, 0, 38);
        // SELL 102 34
        order_batch[4] = pack_order(102, 0, 0, 34);

        send_udp_frame(OP_MARKET, 5);

        #50000; // WAIT 2.66
        $display("[STEP 2] Dumping...");
        send_udp_frame(OP_DUMP, 0);
        #150000;

        $display("=== SIMULATION COMPLETE ===");
        $finish;
    end
    
    // --- OUTPUT MONITOR ---
    integer dump_count = 0;
    always @(posedge clk_udp) begin
        if (tx_fifo_tvalid && tx_fifo_tready) begin
            dump_count = dump_count + 1;
            // The simulation only sends 3 dumps total.
            // If the count runs away (e.g. > 1000 items), something is looping.
            if (dump_count == 2000) begin
                $display("[ERROR] INFINITE DUMP DETECTED! Count > 2000");
                $stop;
            end
        end
    end

endmodule