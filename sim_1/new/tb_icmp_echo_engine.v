`timescale 1ns / 1ps

module tb_icmp_echo_engine();

    // -------------------------------------------------------------------------
    // Testbench Signals
    // -------------------------------------------------------------------------
    reg clk;
    reg rst;

    // AXI Stream Input (Simulating data FROM the MAC)
    reg  [7:0] s_axis_tdata;
    reg        s_axis_tvalid;
    reg        s_axis_tlast;
    wire       s_axis_tready;

    // AXI Stream Output (Simulating data TO the MAC)
    wire [7:0] m_axis_tdata;
    wire       m_axis_tvalid;
    wire       m_axis_tlast;
    reg        m_axis_tready;

    // Status
    wire       ping_detect;

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    icmp_echo_engine dut (
        .clk(clk),
        .rst(rst),
        
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tready(m_axis_tready),
        
        .ping_detect(ping_detect)
    );

    // -------------------------------------------------------------------------
    // Clock Generation (125 MHz)
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #4 clk = ~clk; // 8ns period = 125 MHz
    end

    // -------------------------------------------------------------------------
    // Test Packet Data (Pre-calculated "Hello World" Ping)
    // -------------------------------------------------------------------------
    // Frame Structure:
    // Ethernet (14) | IP (20) | ICMP (8) | Payload (11) = 53 bytes
    // 
    // Payload: "Hello World" -> 48 65 6c 6c 6f 20 57 6f 72 6c 64
    
    reg [7:0] test_packet [0:52];
    
    initial begin
        // --- Ethernet Header ---
        // Dest MAC (Our FPGA): 02:00:00:00:00:00
        test_packet[0] = 8'h02; test_packet[1] = 8'h00; test_packet[2] = 8'h00; 
        test_packet[3] = 8'h00; test_packet[4] = 8'h00; test_packet[5] = 8'h00;
        // Src MAC (PC): AA:BB:CC:DD:EE:FF
        test_packet[6] = 8'hAA; test_packet[7] = 8'hBB; test_packet[8] = 8'hCC; 
        test_packet[9] = 8'hDD; test_packet[10] = 8'hEE; test_packet[11] = 8'hFF;
        // EtherType: IPv4 (0800)
        test_packet[12] = 8'h08; test_packet[13] = 8'h00;

        // --- IP Header ---
        test_packet[14] = 8'h45; // Version 4, Header Len 5
        test_packet[15] = 8'h00; // DiffServ
        test_packet[16] = 8'h00; test_packet[17] = 8'h27; // Total Len (39 bytes)
        test_packet[18] = 8'h00; test_packet[19] = 8'h01; // ID
        test_packet[20] = 8'h00; test_packet[21] = 8'h00; // Flags/Frag
        test_packet[22] = 8'h40; // TTL 64
        test_packet[23] = 8'h01; // Protocol: ICMP (IMPORTANT)
        test_packet[24] = 8'h00; test_packet[25] = 8'h00; // Checksum (Ignored by our engine)
        // Src IP (PC): 192.168.1.50 (C0.A8.01.32)
        test_packet[26] = 8'hC0; test_packet[27] = 8'hA8; test_packet[28] = 8'h01; test_packet[29] = 8'h32;
        // Dest IP (FPGA): 192.168.1.128 (C0.A8.01.80)
        test_packet[30] = 8'hC0; test_packet[31] = 8'hA8; test_packet[32] = 8'h01; test_packet[33] = 8'h80;

        // --- ICMP Header ---
        test_packet[34] = 8'h08; // Type: Echo Request (IMPORTANT)
        test_packet[35] = 8'h00; // Code: 0
        test_packet[36] = 8'hAA; test_packet[37] = 8'hBB; // Checksum (Arbitrary)
        test_packet[38] = 8'h00; test_packet[39] = 8'h01; // ID
        test_packet[40] = 8'h00; test_packet[41] = 8'h01; // Seq

        // --- Payload: "Hello World" ---
        test_packet[42] = "H"; test_packet[43] = "e"; test_packet[44] = "l"; test_packet[45] = "l";
        test_packet[46] = "o"; test_packet[47] = " "; test_packet[48] = "W"; test_packet[49] = "o";
        test_packet[50] = "r"; test_packet[51] = "l"; test_packet[52] = "d";
    end

    // -------------------------------------------------------------------------
    // Main Stimulus Process
    // -------------------------------------------------------------------------
    integer i;
    
    initial begin
        // Initialize
        rst = 1;
        s_axis_tvalid = 0;
        s_axis_tdata = 0;
        s_axis_tlast = 0;
        m_axis_tready = 1; // Always ready to accept reply
        
        // Wait 100ns then release reset
        #100;
        rst = 0;
        #100;

        $display("--- Starting Simulation ---");
        $display("Sending 'Hello World' ICMP Echo Request...");

        // Send Packet
        for (i = 0; i < 53; i = i + 1) begin
            @(posedge clk);
            s_axis_tvalid = 1;
            s_axis_tdata = test_packet[i];
            
            // Assert TLAST on the final byte
            if (i == 52) s_axis_tlast = 1;
            else         s_axis_tlast = 0;

            // Wait if DUT is not ready (Backpressure simulation)
            while (!s_axis_tready) @(posedge clk);
        end

        // End Packet
        @(posedge clk);
        s_axis_tvalid = 0;
        s_axis_tlast = 0;

        // Wait for processing
        #500;
        $display("--- Simulation Complete ---");
        $stop;
    end

    // -------------------------------------------------------------------------
    // Monitor Process (View Output)
    // -------------------------------------------------------------------------
    reg [10:0] out_byte_cnt = 0;
    
    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            
            // Visual check of specific bytes
            if (out_byte_cnt == 0) $display("RX START: Receiving Reply...");
            
            // Check MAC Swap (Byte 0-5 should be Src MAC AA:BB:CC...)
            if (out_byte_cnt == 0) begin
                if (m_axis_tdata == 8'hAA) $display("Check: MAC Dest Swapped Correctly (AA)");
                else $display("ERROR: MAC Dest Incorrect (%h)", m_axis_tdata);
            end

            // Check ICMP Type (Byte 34 should be 00 for Echo Reply)
            if (out_byte_cnt == 34) begin
                if (m_axis_tdata == 8'h00) $display("Check: ICMP Type Changed to Reply (00)");
                else $display("ERROR: ICMP Type Incorrect (%h)", m_axis_tdata);
            end

            // Print Payload characters
            if (out_byte_cnt >= 42) begin
                $write("%c", m_axis_tdata);
            end

            out_byte_cnt = out_byte_cnt + 1;
            
            if (m_axis_tlast) begin
                $write("\n");
                $display("RX END: Packet Complete. Total Bytes: %d", out_byte_cnt);
                if (ping_detect) $display("Check: Ping Detect LED Triggered!");
                else $display("ERROR: Ping Detect LED did not trigger.");
            end
        end
    end

endmodule`timescale 1ns / 1ps

module tb_icmp_echo_engine();

    // -------------------------------------------------------------------------
    // Testbench Signals
    // -------------------------------------------------------------------------
    reg clk;
    reg rst;

    // AXI Stream Input (Simulating data FROM the MAC)
    reg  [7:0] s_axis_tdata;
    reg        s_axis_tvalid;
    reg        s_axis_tlast;
    wire       s_axis_tready;

    // AXI Stream Output (Simulating data TO the MAC)
    wire [7:0] m_axis_tdata;
    wire       m_axis_tvalid;
    wire       m_axis_tlast;
    reg        m_axis_tready;

    // Status
    wire       ping_detect;

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    icmp_echo_engine dut (
        .clk(clk),
        .rst(rst),
        
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tready(m_axis_tready),
        
        .ping_detect(ping_detect)
    );

    // -------------------------------------------------------------------------
    // Clock Generation (125 MHz)
    // -------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #4 clk = ~clk; // 8ns period = 125 MHz
    end

    // -------------------------------------------------------------------------
    // Test Packet Data (Pre-calculated "Hello World" Ping)
    // -------------------------------------------------------------------------
    // Frame Structure:
    // Ethernet (14) | IP (20) | ICMP (8) | Payload (11) = 53 bytes
    // 
    // Payload: "Hello World" -> 48 65 6c 6c 6f 20 57 6f 72 6c 64
    
    reg [7:0] test_packet [0:52];
    
    initial begin
        // --- Ethernet Header ---
        // Dest MAC (Our FPGA): 02:00:00:00:00:00
        test_packet[0] = 8'h02; test_packet[1] = 8'h00; test_packet[2] = 8'h00; 
        test_packet[3] = 8'h00; test_packet[4] = 8'h00; test_packet[5] = 8'h00;
        // Src MAC (PC): AA:BB:CC:DD:EE:FF
        test_packet[6] = 8'hAA; test_packet[7] = 8'hBB; test_packet[8] = 8'hCC; 
        test_packet[9] = 8'hDD; test_packet[10] = 8'hEE; test_packet[11] = 8'hFF;
        // EtherType: IPv4 (0800)
        test_packet[12] = 8'h08; test_packet[13] = 8'h00;

        // --- IP Header ---
        test_packet[14] = 8'h45; // Version 4, Header Len 5
        test_packet[15] = 8'h00; // DiffServ
        test_packet[16] = 8'h00; test_packet[17] = 8'h27; // Total Len (39 bytes)
        test_packet[18] = 8'h00; test_packet[19] = 8'h01; // ID
        test_packet[20] = 8'h00; test_packet[21] = 8'h00; // Flags/Frag
        test_packet[22] = 8'h40; // TTL 64
        test_packet[23] = 8'h01; // Protocol: ICMP (IMPORTANT)
        test_packet[24] = 8'h00; test_packet[25] = 8'h00; // Checksum (Ignored by our engine)
        // Src IP (PC): 192.168.1.50 (C0.A8.01.32)
        test_packet[26] = 8'hC0; test_packet[27] = 8'hA8; test_packet[28] = 8'h01; test_packet[29] = 8'h32;
        // Dest IP (FPGA): 192.168.1.128 (C0.A8.01.80)
        test_packet[30] = 8'hC0; test_packet[31] = 8'hA8; test_packet[32] = 8'h01; test_packet[33] = 8'h80;

        // --- ICMP Header ---
        test_packet[34] = 8'h08; // Type: Echo Request (IMPORTANT)
        test_packet[35] = 8'h00; // Code: 0
        test_packet[36] = 8'hAA; test_packet[37] = 8'hBB; // Checksum (Arbitrary)
        test_packet[38] = 8'h00; test_packet[39] = 8'h01; // ID
        test_packet[40] = 8'h00; test_packet[41] = 8'h01; // Seq

        // --- Payload: "Hello World" ---
        test_packet[42] = "H"; test_packet[43] = "e"; test_packet[44] = "l"; test_packet[45] = "l";
        test_packet[46] = "o"; test_packet[47] = " "; test_packet[48] = "W"; test_packet[49] = "o";
        test_packet[50] = "r"; test_packet[51] = "l"; test_packet[52] = "d";
    end

    // -------------------------------------------------------------------------
    // Main Stimulus Process
    // -------------------------------------------------------------------------
    integer i;
    
    initial begin
        // Initialize
        rst = 1;
        s_axis_tvalid = 0;
        s_axis_tdata = 0;
        s_axis_tlast = 0;
        m_axis_tready = 1; // Always ready to accept reply
        
        // Wait 100ns then release reset
        #100;
        rst = 0;
        #100;

        $display("--- Starting Simulation ---");
        $display("Sending 'Hello World' ICMP Echo Request...");

        // Send Packet
        for (i = 0; i < 53; i = i + 1) begin
            @(posedge clk);
            s_axis_tvalid = 1;
            s_axis_tdata = test_packet[i];
            
            // Assert TLAST on the final byte
            if (i == 52) s_axis_tlast = 1;
            else         s_axis_tlast = 0;

            // Wait if DUT is not ready (Backpressure simulation)
            while (!s_axis_tready) @(posedge clk);
        end

        // End Packet
        @(posedge clk);
        s_axis_tvalid = 0;
        s_axis_tlast = 0;

        // Wait for processing
        #500;
        $display("--- Simulation Complete ---");
        $stop;
    end

    // -------------------------------------------------------------------------
    // Monitor Process (View Output)
    // -------------------------------------------------------------------------
    reg [10:0] out_byte_cnt = 0;
    
    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            
            // Visual check of specific bytes
            if (out_byte_cnt == 0) $display("RX START: Receiving Reply...");
            
            // Check MAC Swap (Byte 0-5 should be Src MAC AA:BB:CC...)
            if (out_byte_cnt == 0) begin
                if (m_axis_tdata == 8'hAA) $display("Check: MAC Dest Swapped Correctly (AA)");
                else $display("ERROR: MAC Dest Incorrect (%h)", m_axis_tdata);
            end

            // Check ICMP Type (Byte 34 should be 00 for Echo Reply)
            if (out_byte_cnt == 34) begin
                if (m_axis_tdata == 8'h00) $display("Check: ICMP Type Changed to Reply (00)");
                else $display("ERROR: ICMP Type Incorrect (%h)", m_axis_tdata);
            end

            // Print Payload characters
            if (out_byte_cnt >= 42) begin
                $write("%c", m_axis_tdata);
            end

            out_byte_cnt = out_byte_cnt + 1;
            
            if (m_axis_tlast) begin
                $write("\n");
                $display("RX END: Packet Complete. Total Bytes: %d", out_byte_cnt);
                if (ping_detect) $display("Check: Ping Detect LED Triggered!");
                else $display("ERROR: Ping Detect LED did not trigger.");
            end
        end
    end

endmodule