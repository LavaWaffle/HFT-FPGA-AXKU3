`timescale 1ns / 1ps

// Define macros locally
`ifndef PRICE
    `define PRICE(x) x[31:16]
    `define IS_BUY(x) x[15]
    `define IS_BOT(x) x[14]
    `define QTY(x)   x[13:0]
`endif

module tb_uart_udp_integration;

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
    
    // UDP Return Path
    wire [7:0]  udp_tx_tdata;
    wire        udp_tx_tvalid;
    reg         udp_tx_tready = 1; // Always ready

    // UART Interface
    reg         uart_rx_in = 1;    // Idle high (Stop bit state)
    wire        uart_tx_out;
    
    // Debug
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

    // UART Baud Config (Needs to match simulation time)
    // 125MHz / 115200 = ~1085 clocks per bit
    // Note: To speed up simulation, you can change the DUT baud rate 
    // parameter, but for accuracy, we keep it standard here.
    localparam BAUD_CLKS = 1085;
    localparam BIT_PERIOD = 8.0 * BAUD_CLKS; // 8ns * 1085

    // Buffer
    reg [31:0] order_batch [0:15]; 

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
        
        .udp_tx_tdata(udp_tx_tdata),
        .udp_tx_tvalid(udp_tx_tvalid),
        .udp_tx_tready(udp_tx_tready),
        
        .uart_rx_in(uart_rx_in),
        .uart_tx_out(uart_tx_out),

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
    
    // Send UDP Packet
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
        
        integer i, k;
        reg [7:0] current_byte;
        reg [31:0] current_order;
        begin
            // Header
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

            // Opcode
            send_byte(opcode[23:16], 0);
            send_byte(opcode[15:8],  0);
            send_byte(opcode[7:0],   0);

            // Payload
            if (count == 0) begin
                send_byte(8'h00, 1);
            end else begin
                for (k = 0; k < count; k = k + 1) begin
                    current_order = order_batch[k];
                    send_byte(current_order[31:24], 0);
                    send_byte(current_order[23:16], 0);
                    send_byte(current_order[15:8],  0);
                    if (k == count - 1) send_byte(current_order[7:0], 1);
                    else                send_byte(current_order[7:0], 0);
                end
            end

            @(posedge clk_udp);
            rx_axis_tvalid <= 0;
            rx_axis_tlast  <= 0;
            rx_axis_tdata  <= 0;
            repeat(100) @(posedge clk_udp);
        end
    endtask

    // Send UART Byte (Bit-Bang)
    task send_uart_byte;
        input [7:0] data;
        integer i;
        begin
            // Start Bit (Low)
            uart_rx_in = 0;
            #(BIT_PERIOD);
            
            // Data Bits (LSB First)
            for (i=0; i<8; i=i+1) begin
                uart_rx_in = data[i];
                #(BIT_PERIOD);
            end
            
            // Stop Bit (High)
            uart_rx_in = 1;
            #(BIT_PERIOD);
            
            // Tiny inter-byte delay
            #(BIT_PERIOD); 
        end
    endtask
    
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
    // 5. UART Monitor (Helper to visualize output)
    // =================================================================
    reg [7:0] captured_byte;
    integer bit_cnt;
    
    initial begin
        forever begin
            // Wait for start bit (falling edge)
            @(negedge uart_tx_out);
            
            // Wait 1.5 bit periods to sample middle of bit 0
            #(BIT_PERIOD * 1.5);
            
            for (bit_cnt = 0; bit_cnt < 8; bit_cnt = bit_cnt + 1) begin
                captured_byte[bit_cnt] = uart_tx_out;
                #(BIT_PERIOD);
            end
            
            $display("[UART OUT] Received Byte: %h (Time: %t)", captured_byte, $time);
        end
    end

    // =================================================================
    // 6. Main Test Sequence
    // =================================================================
   initial begin
        // Setup Waveform dumping
        $dumpfile("uart_dump_test.vcd");
        $dumpvars(0, tb_uart_udp_integration);
        
        $display("=== UART + UDP INTEGRATION TEST ===");
        
        // Reset
        rst_udp = 1; rst_engine = 1;
        #100;
        rst_udp = 0; rst_engine = 0;
        #100;

        // --- CRITICAL FIX: WAIT FOR BRAM INITIALIZATION ---
        // The Heap Manager takes ~5.2us (1024 cycles @ 200MHz) to zero out BRAMs.
        // If we send data before that, it gets ignored.
        $display("[INFO] Waiting for BRAM Initialization...");
        #100000; 
        
        // ----------------------------------------------------------------
        // TEST 1: Populate Book via UDP
        // ----------------------------------------------------------------
        $display("\n[TEST 1] Populating Book via UDP...");
        
        order_batch[0] = pack_order(105, 0, 0, 10); // Sell 10 @ 105
        order_batch[1] = pack_order(100, 0, 0, 20); // Sell 20 @ 100
        
        send_udp_frame(OP_MARKET, 2);
        
        #5000; // Allow engine to process

        // ----------------------------------------------------------------
        // TEST 2: Request Dump via UART
        // ----------------------------------------------------------------
        $display("\n[TEST 2] Sending Dump Trigger via UART (F0 E0 D0)...");
        
        // Send Trigger Sequence at 115200 baud
        send_uart_byte(8'hF0);
        send_uart_byte(8'hE0);
        send_uart_byte(8'hD0);
        
        $display("    [INFO] UART Command Sent. Waiting for response...");
        
        // Wait for processing and transmission time
        // 8 bytes (2 orders x 4 bytes) + overhead = ~1ms at 115200 baud
        // We wait 2ms to be safe.
        #2000000; 

        $display("=== TEST COMPLETE ===");
        $finish;
    end

endmodule