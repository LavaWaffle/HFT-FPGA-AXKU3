`timescale 1ns / 1ps

// Define macros locally for readability
`ifndef PRICE
    `define PRICE(x) x[31:16]
    `define IS_BUY(x) x[15]
    `define IS_BOT(x) x[14]
    `define QTY(x)    x[13:0]
`endif

`define CLKS_PER_BIT 1736
`define T_BIT_TIME_NS CLKS_PER_BIT * 5

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

    // --- UART Timing Constant (Must match uart_core.v) ---
    localparam CLKS_PER_BIT = 1736; // 200 MHz / 115200 baud
    localparam T_BIT_TIME_NS = 1736 * 5; // 8680 ns (CLKS_PER_BIT * T_CLK_NS)

    // --- LOW-LEVEL UART PINS & Wires ---
    reg  uart_rx_i = 1'b1;         // Raw asynchronous input pin for receiver module
    wire uart_tx_o;                // Raw asynchronous output pin from TX Channel
    
    wire [7:0] uart_rx_data_out_synced; // Output of receiver core (200MHz synced data)
    wire uart_rx_data_valid_synced;     // Output of receiver core (200MHz synced pulse)

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

    // Filter Constants (Must match your UDP Extractor settings)
    localparam [31:0] DEST_IP  = {8'd192, 8'd168, 8'd1, 8'd50};    
    localparam [15:0] SRC_PORT = 16'd55555;                          
    
    localparam [23:0] OP_MARKET = 24'h102030;
    localparam [23:0] OP_DUMP   = 24'hF0E0D0;
    
    // GLOBAL BUFFER for Packet Generation
    reg [31:0] order_batch [0:63]; 

    // =================================================================
    // 2. Instantiate System Components
    // =================================================================

    // 2a. UART Receiver Instance (RX core must run in the 200MHz domain)
    // The 'receiver' module is renamed to 'uart_receiver' for consistency
    uart_receiver uart_rx_inst (
        .i_Clock     (clk_engine),
        .i_Rx_Serial (uart_rx_i),           // Raw asynchronous input (driven by stimulus task)
        .o_Rx_DV     (uart_rx_data_valid_synced),
        .o_Rx_Byte   (uart_rx_data_out_synced)
    );

    // 2b. Trading System Top (The core logic wrapper)
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
        .debug_ob_data(debug_ob_data),
        
        // --- UART Connections (Receiving synchronized RX data) ---
        .uart_rx_data_out(uart_rx_data_out_synced),
        .uart_rx_data_valid(uart_rx_data_valid_synced),
        
        // --- UART Connections (TX channel signals are internal wires in uut) ---
        .uart_tx_data_in(uart_tx_data_in),
        .uart_tx_data_valid(uart_tx_data_valid),
        .uart_tx_ready(uart_tx_ready),
        
        // --- Debug FIFO status (added for completeness) ---
        .debug_input_fifo_empty(debug_input_fifo_empty),
        .debug_input_fifo_full(debug_input_fifo_full)
    );

    // 2c. UART TX Channel Instantiation (Must run in the 200MHz domain)
    // Connects the high-speed FIFO signals (from uut's internal logic) to the low-speed core
    uart_tx_channel uart_tx_channel_inst (
        .clk          (clk_engine),
        .rst          (rst_engine), 
        .tx_data_in   (uut.uart_tx_data_in),    // Wire from uut's internal FIFO output
        .tx_valid_in  (uut.uart_tx_data_valid), // Wire from uut's internal FIFO not empty
        .tx_ready_out (uut.uart_tx_ready),      // Wire to uut's internal FIFO read enable
        .fpga_uart_tx (uart_tx_o)               // Raw asynchronous output (monitor this!)
    );


    // =================================================================
    // 3. Clock Generation
    // =================================================================
    // Time must be simulated precisely to match the CLKS_PER_BIT macro
    always #4.0 clk_udp    = ~clk_udp;    // 125 MHz 
    always #2.5 clk_engine = ~clk_engine; // 200 MHz 

    // =================================================================
    // 4. Helper Tasks
    // =================================================================
    
    // Send UART bytes (slowly, simulating external device)
    task send_uart_byte;
        input [7:0] data;
        begin
            // 0. Wait for clock edge to synchronize state change 
            @(posedge clk_engine);
            
            // 1. Send Start Bit (0)
            uart_rx_i <= 1'b0;
            #(T_BIT_TIME_NS);
            
            // 2. Send 8 Data Bits (LSB first) - Hold for 1 * T_Bit each
            for (integer i = 0; i < 8; i = i + 1) begin
                uart_rx_i <= data[i];
                #(T_BIT_TIME_NS); 
            end
            
            // 3. Send Stop Bit (1) - Hold for 1 * T_Bit
            uart_rx_i <= 1'b1;
            #(T_BIT_TIME_NS);   
        end
    endtask

    // Send UART DUMP Command (FE 00)
    task send_uart_dump_command;
        begin
            $display("[%0t] UART STIMULUS: Sending DUMP Command (FE 00)", $time);
            send_uart_byte(8'hFE);
            send_uart_byte(8'h00);
            $display("[%0t] UART STIMULUS: Command sequence complete.", $time);
            #100;
        end
    endtask


    // Low-level UDP byte sender (Original code, kept for completeness)
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

    // Send UDP Frame (Header + Opcode + Payload) (Original code, kept for completeness)
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
    // 5. Monitors
    // =================================================================
    
    // UDP Dump Monitor (Original code, kept for completeness)
    initial begin
        tx_fifo_tready = 1;    
        forever begin
            @(posedge clk_udp);
            if (tx_fifo_tvalid) begin
                $display("[%0t] DUMP OUTPUT (UDP): %h", $time, tx_fifo_tdata);
            end
        end
    end

    // UART TX Monitor (Simulated Serial output)
    initial begin
        forever begin
            @(negedge uart_tx_o);
            // Monitor the raw UART pin transition. 
            // This is complex to decode reliably in pure Verilog, 
            // so we rely on the simulator waveform viewer and Tx Done pulses.
             $display("[%0t] UART TX PIN: Transition detected on fpga_uart_tx.", $time);
        end
    end
    
    // Trade Execution Monitor (Original code, kept for completeness)
    always @(posedge clk_engine) begin
        if (trade_valid) begin
            $display("[%0t] >>> TRADE EXEC: Price %0d, Qty %0d <<<",    
                     $time, `PRICE(trade_info), `QTY(trade_info));
        end
    end
    
    // UART TX Done Pulse Monitor
    always @(posedge clk_engine) begin
        if (uart_tx_channel_inst.tx_done_pulse) begin
            $display("[%0t] UART TX CHANNEL: Low-Level Tx Done Pulse detected.", $time);
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
        
        #10000;
        
        // Initialize UART RX pin to IDLE state (High)
        uart_rx_i <= 1'b1;

        #10000;

        // ----------------------------------------------------------------
        // TEST 1: ROUTING & BASIC POPULATION (UDP)
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

        $display("\n[TEST 1.5] Dumping Book via UDP...");
        send_udp_frame(OP_DUMP, 0);
        #3000;
        
        #50000;

        send_uart_dump_command;

        #99999999;

        // ----------------------------------------------------------------
        // TEST 2: SORTING & PRIORITY (UDP)
        // ----------------------------------------------------------------
//        $display("\n[TEST 2] Sorting & Priority Check...");
        
        // Current Ask is 105.
        // Insert 100 (Better), 102 (Middle), 108 (Worse)
//        order_batch[0] = pack_order(100, 0, 0, 10);
//        order_batch[1] = pack_order(102, 0, 0, 10);
//        order_batch[2] = pack_order(108, 0, 0, 10);
        
//        send_udp_frame(OP_MARKET, 3);
//        #2000;
        
        // ----------------------------------------------------------------
        // TEST 3: DUPLICATE PRICE HANDLING (UDP)
        // ----------------------------------------------------------------
//        $display("\n[TEST 3] Duplicate Price Injection...");
        
//        order_batch[0] = pack_order(102, 0, 0, 5);
//        send_udp_frame(OP_MARKET, 1);
//        #1000;
        
//        // Total Asks: 105, 100, 102, 108 + new 102 = 5 Orders
//        check_heap_counts(1, 5);

//        // ----------------------------------------------------------------
//        // TEST 4: UART DUMP TRIGGER & TX VERIFICATION
//        // Send command FE 00 via UART. Trigger slow serial dump.
//        // Heaps currently contain 1 Bid, 5 Asks = 6 total orders (6 * 4 bytes = 24 bytes)
//        // Plus 4 bytes header and 1 byte footer = 29 bytes total.
//        // ----------------------------------------------------------------
//        $display("\n[TEST 4] UART DUMP TRIGGER Check and TX Verification...");
        
//        // Wait for UDP engine to clear before starting the dump
//        repeat(10) @(posedge clk_engine); 
        
//        // Send the DUMP command (FE 00)
//        send_uart_dump_command;
        
//        // Wait for the full DUMP sequence to finish sending over the slow UART
//        // 29 bytes * 8.68 us/byte * 1.2 overhead * 1000 = ~300,000 ns simulation time
//        #300000; 

//        $display("\n[TEST 4.5] Post UART Dump Check...");
//        check_heap_counts(1, 5); // Heaps should be unchanged (1 Bid + 5 Asks)

//        // ----------------------------------------------------------------
//        // TEST 5: THE BIG SWEEP (Execution Logic) (UDP)
//        // ----------------------------------------------------------------
//        $display("\n[TEST 5] The Sweep (Buy 55 @ 110)...");
        
//        order_batch[0] = pack_order(110, 1, 0, 55);
//        send_udp_frame(OP_MARKET, 1);
        
//        #3000;
        
//        $display("\n[TEST 6] (Sell 5 @ 60)...");
        
//        order_batch[0] = pack_order(110, 0, 1, 15);
//        send_udp_frame(OP_MARKET, 1);
        
//        #3000;
        
//        // Check Final State
//        $display("--- POST SWEEP STATUS ---");
//        check_heap_counts(2, 1); 

//        $display("---DUMP POST SWEEP (UDP) ---");
//        send_udp_frame(OP_DUMP, 0);
        
//        #3000;

        $display("\n=== TEST COMPLETE ===");
        $finish;
    end

endmodule