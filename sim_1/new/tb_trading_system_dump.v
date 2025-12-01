`timescale 1ns / 1ps

module tb_trading_system_dump;

    // =================================================================
    // 1. Signals
    // =================================================================
    // Clocks & Resets
    reg clk_udp = 0;
    reg rst_udp = 1;
    reg clk_engine = 0;
    reg rst_engine = 1;

    // UDP RX Stream (Input to FPGA)
    reg [7:0]  rx_axis_tdata = 0;
    reg        rx_axis_tvalid = 0;
    reg        rx_axis_tlast = 0;

    // UDP TX Return Path (Output from FPGA)
    wire [7:0] tx_fifo_tdata;
    wire       tx_fifo_tvalid;
    reg        tx_fifo_tready = 0; // We will simulate the UDP TX Engine reading

    // Debug / Status
    wire [31:0] trade_info;
    wire        trade_valid;
    wire        engine_busy;
    wire [31:0] debug_ob_data;

    // =================================================================
    // 2. Instantiate the Wrapper
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
        .leds(),
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
    // 4. Tasks (Packet Generators)
    // =================================================================
    
    // Low-level Byte Sender
    task send_byte(input [7:0] data);
        begin
            @(posedge clk_udp);
            rx_axis_tvalid <= 1;
            rx_axis_tdata  <= data;
            rx_axis_tlast  <= 0;
        end
    endtask

    // TASK: Send Market Data (Opcode 0x102030)
    task send_order_packet(input [15:0] price, input is_buy, input [13:0] qty);
        integer i;
        reg [31:0] payload;
        begin
            // 1. Header Garbage (42 Bytes) - Must be valid IPv4/UDP for filter
            // Filter Constants: IP=192.168.1.50 (C0.A8.01.32), Port=55555 (D903)
            // We must construct a "valid" header for the Extractor to accept it.
            // Bytes 0-29: Garbage
            for (i=0; i<12; i=i+1) send_byte(8'hAA); // MACs
            send_byte(8'h08); send_byte(8'h00);      // EtherType (IPv4)
            for (i=0; i<9; i=i+1) send_byte(8'h00);
            send_byte(8'h11);                        // Protocol (UDP)
            for (i=0; i<6; i=i+1) send_byte(8'h00);
            
            // Byte 30-33: Dest IP (192.168.1.50)
            send_byte(8'hC0); send_byte(8'hA8); send_byte(8'h01); send_byte(8'h32);
            
            // Byte 34-35: Src Port (55555 -> 0xD903)
            send_byte(8'hD9); send_byte(8'h03);
            
            // Byte 36-41: More Garbage
            for (i=0; i<6; i=i+1) send_byte(8'h00);

            // 2. OPCODE (3 Bytes) - MARKET DATA
            send_byte(8'h10); send_byte(8'h20); send_byte(8'h30);

            // 3. PAYLOAD (4 Bytes) - Aligned
            // Pack: Price | Buy | Bot | Qty
            payload = {price, is_buy, 1'b0, qty};
            
            // Send Big Endian (Network Order)
            send_byte(payload[31:24]); 
            send_byte(payload[23:16]); 
            send_byte(payload[15:8]);  
            
            // Last Byte with TLAST
            @(posedge clk_udp);
            rx_axis_tdata  <= payload[7:0]; 
            rx_axis_tlast  <= 1;
            
            @(posedge clk_udp);
            rx_axis_tvalid <= 0;
            rx_axis_tlast  <= 0;
            rx_axis_tdata  <= 0;
            
            // Wait for processing
            repeat(20) @(posedge clk_udp);
        end
    endtask

    // TASK: Send Dump Command (Opcode 0xF0E0D0)
    task trigger_book_dump;
        integer i;
        begin
            // 1. Send Valid Header
            for (i=0; i<12; i=i+1) send_byte(8'hAA); 
            send_byte(8'h08); send_byte(8'h00);      
            for (i=0; i<9; i=i+1) send_byte(8'h00);
            send_byte(8'h11);                        
            for (i=0; i<6; i=i+1) send_byte(8'h00);
            send_byte(8'hC0); send_byte(8'hA8); send_byte(8'h01); send_byte(8'h32);
            send_byte(8'hD9); send_byte(8'h03);
            for (i=0; i<6; i=i+1) send_byte(8'h00);

            // 2. OPCODE (3 Bytes) - DUMP BOOK
            send_byte(8'hF0); send_byte(8'hE0); 
            
            // Last Byte with TLAST (Opcode is end of packet for command)
            @(posedge clk_udp);
            rx_axis_tdata  <= 8'hD0; 
            rx_axis_tvalid <= 1;
            rx_axis_tlast  <= 1;
            
            @(posedge clk_udp);
            rx_axis_tvalid <= 0;
            rx_axis_tlast  <= 0;
            
            $display("[TB] Sent DUMP Trigger Packet");
            repeat(20) @(posedge clk_udp);
        end
    endtask

    // =================================================================
    // 5. Main Test Sequence
    // =================================================================
    initial begin
        $display("=== STARTING DUMP TEST ===");
        
        // Reset
        #100;
        rst_udp = 0;
        rst_engine = 0; 
        #100;

        // 1. POPULATE THE BOOK
        // We submit orders. The Heap Manager should store them in BRAM.
        $display("[TB] Populating Book...");
        
        // Sell @ 100, Qty 10
        send_order_packet(16'd1, 1'b0, 14'd1); 
        
        // Buy @ 90, Qty 50
        send_order_packet(16'd1,  1'b0, 14'd1); 
        
        // Sell @ 105, Qty 5
        send_order_packet(16'd1, 1'b0, 14'd1);  

        // Allow time for heaps to settle and write to RAM
        #1000; 

        // 2. TRIGGER THE DUMP
        $display("[TB] Triggering Dump...");
        trigger_book_dump();

        // 3. READ THE RETURN STREAM
        // The UDP TX Engine is simulated here by manually setting 'tready' high.
        // We should see the data pouring out of the return FIFO.
        
        // Enable reading from return FIFO
        tx_fifo_tready = 1; 
        
        // Wait and observe waveforms
        #20000;
        
        $display("=== TEST COMPLETE ===");
        $finish;
    end
    
    // Monitor Output
    always @(posedge clk_udp) begin
        if (tx_fifo_tvalid && tx_fifo_tready) begin
            $display("[RETURN PATH] Byte Received: %h", tx_fifo_tdata);
        end
    end

endmodule