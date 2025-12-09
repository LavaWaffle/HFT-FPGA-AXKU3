`timescale 1ns / 1ps

module tb_fpga_top;

    // =========================================================================
    // 1. SIGNALS & CLOCK GENERATION
    // =========================================================================
    
    // System Clock (200 MHz Differential)
    reg sys_clk_p;
    wire sys_clk_n;
    assign sys_clk_n = ~sys_clk_p;

    // SFP Reference Clock (125 MHz Differential)
    reg gt_refclk_p;
    wire gt_refclk_n;
    assign gt_refclk_n = ~gt_refclk_p;

    // Reset (Active Low)
    reg rst_n;

    // SFP Serial Lines (Ignored)
    wire sfp_tx_p, sfp_tx_n;
    
    // UART
    reg uart_rx;
    wire uart_tx;
    
    // LEDs
    wire [3:0] led;

    // 200 MHz Clock (5ns period)
    initial begin
        sys_clk_p = 0;
        forever #2.5 sys_clk_p = ~sys_clk_p;
    end

    // 125 MHz Clock (8ns period)
    initial begin
        gt_refclk_p = 0;
        forever #4.0 gt_refclk_p = ~gt_refclk_p;
    end

    // =========================================================================
    // 2. DUT INSTANTIATION
    // =========================================================================
    fpga_top dut (
        .sys_clk_p(sys_clk_p),
        .sys_clk_n(sys_clk_n),
        .rst_n(rst_n),
        .sfp_rx_p(1'b0), // Ignored due to force
        .sfp_rx_n(1'b1), // Ignored
        .sfp_tx_p(sfp_tx_p),
        .sfp_tx_n(sfp_tx_n),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .gt_refclk_p(gt_refclk_p),
        .gt_refclk_n(gt_refclk_n),
        .led(led)
    );

    // =========================================================================
    // 3. TASKS: PACKET DRIVERS (Verilog 2001 Compatible)
    // =========================================================================
    
    // Task to send a single byte via forced GMII
    task send_byte;
        input [7:0] data;
        begin
            // Force signals on the internal wires of the FPGA top module
            // WARNING: Ensure path 'dut.eth_phy_inst' matches your hierarchy
            force dut.gmii_rxd = data;
            force dut.gmii_rx_dv = 1;
            @(posedge dut.clk_125m); 
        end
    endtask

    // Task to send Ethernet/IP/UDP Header
    // Total Length hardcoded for 2 words (8 bytes) of payload for this specific test
    task send_headers;
        input [31:0] payload_len_bytes;
        integer i;
        begin
            // --- Preamble (7 bytes) + SFD (1 byte) ---
            for(i=0; i<7; i=i+1) send_byte(8'h55);
            send_byte(8'hD5);

            // --- Ethernet Header ---
            // Dest MAC (FPGA): 02:00:00:00:00:00
            send_byte(8'h02); send_byte(8'h00); send_byte(8'h00); 
            send_byte(8'h00); send_byte(8'h00); send_byte(8'h00);
            
            // Src MAC: 11:22:33:44:55:66
            send_byte(8'h11); send_byte(8'h22); send_byte(8'h33); 
            send_byte(8'h44); send_byte(8'h55); send_byte(8'h66);
            
            // EtherType: IPv4 (0800)
            send_byte(8'h08); send_byte(8'h00);

            // --- IP Header ---
            send_byte(8'h45); // Version/IHL
            send_byte(8'h00); // TOS
            // Total IP Length = 20(IP) + 8(UDP) + Payload
            send_byte(8'h00); send_byte(28 + payload_len_bytes); 
            
            send_byte(8'h00); send_byte(8'h00); // ID
            send_byte(8'h00); send_byte(8'h00); // Flags
            send_byte(8'h40); // TTL
            send_byte(8'h11); // Protocol UDP
            send_byte(8'h00); send_byte(8'h00); // Checksum (Ignored)
            
            // Src IP: 192.168.1.128
            send_byte(192); send_byte(168); send_byte(1); send_byte(128);
            // Dst IP: 192.168.1.50 (FPGA)
            send_byte(192); send_byte(168); send_byte(1); send_byte(50);

            // --- UDP Header ---
            // Src Port: 55555 (D9 03)
            send_byte(8'hD9); send_byte(8'h03);
            // Dst Port: 50000 (C3 50)
            send_byte(8'hC3); send_byte(8'h50);
            // UDP Length = 8 + Payload
            send_byte(8'h00); send_byte(8 + payload_len_bytes);
            // Checksum
            send_byte(8'h00); send_byte(8'h00);
        end
    endtask

    // Task to finish packet
    task end_packet;
        integer i;
        begin
            // Send Dummy CRC (4 bytes)
            send_byte(8'hDE); send_byte(8'hAD); send_byte(8'hBE); send_byte(8'hEF);
            
            // Release bus
            force dut.gmii_rx_dv = 0;
            force dut.gmii_rxd = 8'h00;
            
            // Inter-frame gap
            for(i=0; i<12; i=i+1) @(posedge dut.clk_125m);
        end
    endtask
    
    task wait_for_state;
        input [2:0] target_state;
        input integer timeout_cycles;
        
        integer loops;
        reg [2:0] current_state;
        begin
            loops = 0;
            current_state = dut.trading_sys.r_System_State;
            
            // Loop until state matches or timeout
            while ((current_state !== target_state) && (loops < timeout_cycles)) begin
                @(posedge sys_clk_p);
                current_state = dut.trading_sys.r_System_State;
                loops = loops + 1;
            end

            if (current_state === target_state) begin
                $display("[TB INFO] FSM reached target state %d at time %t", target_state, $time);
            end else begin
                $display("[TB ERROR] Timeout waiting for FSM state %d. Current: %d", target_state, current_state);
                $stop; // Pause simulation on error
            end
        end
    endtask
    
    // Monitor: Watch outgoing UDP packets on GMII TX
    // Prints bytes to console whenever gmii_tx_en is high
    always @(posedge dut.clk_125m) begin
        // Detect start of packet (Rising Edge of TX_EN)
        if (dut.gmii_tx_en && !dut.eth_phy_inst.gmii_tx_en) begin 
            // Note: Accessing internal reg/wire previous value is hard without storage
            // easier to just check if this is the first cycle
            $write("\n[TX PACKET START] Data: ");
        end
        
        // Print valid data
        if (dut.gmii_tx_en) begin
            $write("%h ", dut.gmii_txd);
        end
        
        // Detect end of packet (Falling Edge logic simulation)
        // Since we are in an always block, we can't easily see "falling edge" 
        // without a register. This simpler version adds a newline when IDLE.
        if (!dut.gmii_tx_en) begin
             // Optional: Logic to prevent spamming newlines
        end
    end

    // To make the output cleaner, you can use this latch-based monitor instead:
    reg prev_tx_en;
    initial prev_tx_en = 0;
    
    always @(posedge dut.clk_125m) begin
        if (dut.gmii_tx_en) begin
            if (!prev_tx_en) $write("\n[UDP TX OUT] Time %t: ", $time);
            $write("%h ", dut.gmii_txd);
        end else if (prev_tx_en) begin
            $write("\n"); // End of packet
        end
        prev_tx_en <= dut.gmii_tx_en;
    end

    // =========================================================================
    // 4. MAIN TEST PROCESS
    // =========================================================================
    
    integer j;

    initial begin
        $display("### SIMULATION START ###");
        rst_n = 0;
        uart_rx = 1;
        
        // Wait 100 cycles
        for(j=0; j<100; j=j+1) @(posedge sys_clk_p);
        #90000;
        
        rst_n = 1;
        $display("### RESET RELEASED ###");
        
        // Wait 500 cycles for logic to settle
        for(j=0; j<500; j=j+1) @(posedge sys_clk_p);

        // ---------------------------------------------------------------------
        // 1. INJECT BUY ORDER
        // ---------------------------------------------------------------------
        wait_for_state(3'd2, 500_000_000);
        
        $display("### 1. INJECTING BUY ORDER ###");
        // Structure: OpCode(3B) | Index(2B) | Pad(1B) | Data(4B)
        // Data format: 10 20 01 00 | 64 C0 0A 00
        // Price=100 (0x64), Buy=1, ID=1, Qty=10
        
        send_headers(8); // 8 bytes of payload
        
        // Word 1: 10 20 30 (Opcode) + 00 (Padding/Index part)
        // Adjusting to match Extractor expectations:
        // Byte 42: 10
        // Byte 43: 20
        // Byte 44: 01 (Index LSB)
        // Byte 45: 00 (Price MSB)
        send_byte(8'h10); send_byte(8'h20); send_byte(8'h01); send_byte(8'h00);
        
        // Word 2: 
        // Byte 46: 64 (Price LSB)
        // Byte 47: C0 (Side=1, ID=1, Qty MSB=0)
        // Byte 48: 0A (Qty LSB)
        // Byte 49: 00 (Pad)
        send_byte(8'h64); send_byte(8'hC0); send_byte(8'h0A); send_byte(8'h00);
        
        end_packet();

        // Wait for processing
        for(j=0; j<500; j=j+1) @(posedge sys_clk_p);
        
        // CHECK HEAP SIZE (Whitebox)
        // Hierarchical path: dut.trading_sys.ob_inst.u_bid_heap.count
        if (dut.trading_sys.ob_inst.u_bid_heap.count == 1) 
            $display("SUCCESS: Bid Heap Count is 1");
        else 
            $display("FAILURE: Bid Heap Count is %d (Expected 1)", dut.trading_sys.ob_inst.u_bid_heap.count);

        // ---------------------------------------------------------------------
        // 2. INJECT SELL ORDER (No Match)
        // ---------------------------------------------------------------------
        $display("### 2. INJECTING SELL ORDER ###");
        // Price=110 (0x6E), Sell=0, ID=1, Qty=10 -> 0x006E 400A (Bit 15=0, Bit 14=1)
        
        send_headers(8);
        
        // Byte 42-45: 10 20 02 00 (Index 2, Price MSB 0)
        send_byte(8'h10); send_byte(8'h20); send_byte(8'h02); send_byte(8'h00);
        
        // Byte 46-49: 6E 40 0A 00 (Price LSB, Sell/ID/QtyMSB, QtyLSB, Pad)
        send_byte(8'h6E); send_byte(8'h40); send_byte(8'h0A); send_byte(8'h00);
        
        end_packet();

        for(j=0; j<500; j=j+1) @(posedge sys_clk_p);

        // CHECK HEAP SIZE
        if (dut.trading_sys.ob_inst.u_ask_heap.count == 1) 
            $display("SUCCESS: Ask Heap Count is 1");
        else 
            $display("FAILURE: Ask Heap Count is %d (Expected 1)", dut.trading_sys.ob_inst.u_ask_heap.count);

        // ---------------------------------------------------------------------
        // 3. INJECT DUMP REQUEST
        // ---------------------------------------------------------------------
        $display("### 3. INJECTING DUMP REQUEST ###");
        // OpCode: F0 E0 D0
        
        send_headers(4); // Only 4 bytes needed for command
        
        // F0 E0 D0 00
        send_byte(8'hF0); send_byte(8'hE0); send_byte(8'hD0); send_byte(8'h00);
        
        end_packet();

        // ---------------------------------------------------------------------
        // 4. MONITOR OUTPUT (Dump Check)
        // ---------------------------------------------------------------------
        $display("### 4. MONITORING FOR DUMP OUTPUT ###");
        
        // Simple timeout loop to check for activity
        // We look for dut.gmii_tx_en going high
        
        for(j=0; j<5000; j=j+1) begin
            @(posedge dut.clk_125m);
            if (dut.gmii_tx_en == 1) begin
                $display("SUCCESS: Detected GMII TX Activity at time %t", $time);
                
                // Print a few bytes
                $display("TX Byte: %h", dut.gmii_txd);
                @(posedge dut.clk_125m); $display("TX Byte: %h", dut.gmii_txd);
                @(posedge dut.clk_125m); $display("TX Byte: %h", dut.gmii_txd);
                @(posedge dut.clk_125m); $display("TX Byte: %h", dut.gmii_txd);
                
                // Exit successfully
                j = 5000; // Break loop
            end
        end

        $display("### SIMULATION COMPLETE ###");
        $finish;
    end

endmodule