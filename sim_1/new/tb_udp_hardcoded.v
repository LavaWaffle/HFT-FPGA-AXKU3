`timescale 1ns / 1ps

module tb_udp_hardcoded;

    // Inputs
    reg clk;
    reg rst;
    reg [7:0] s_axis_tdata;
    reg s_axis_tvalid;
    reg s_axis_tlast;
    reg m_axis_tready;

    // Outputs
    wire s_axis_tready;
    wire [7:0] m_axis_tdata;
    wire m_axis_tvalid;
    wire m_axis_tlast;

    // Instantiate the Hardcoded UUT
    udp_hardcoded_echo uut (
        .clk(clk), 
        .rst(rst), 
        .s_axis_tdata(s_axis_tdata), 
        .s_axis_tvalid(s_axis_tvalid), 
        .s_axis_tlast(s_axis_tlast), 
        .s_axis_tready(s_axis_tready), 
        .m_axis_tdata(m_axis_tdata), 
        .m_axis_tvalid(m_axis_tvalid), 
        .m_axis_tlast(m_axis_tlast), 
        .m_axis_tready(m_axis_tready)
    );

    // Clock generation (125 MHz approx)
    always #4 clk = ~clk; 

    // Byte counters for verification
    integer out_byte_cnt = 0;

    // Helper task to send data
    task send_byte;
        input [7:0] data;
        input last;
        begin
            @(posedge clk);
            s_axis_tvalid <= 1;
            s_axis_tdata <= data;
            s_axis_tlast <= last;
            while(s_axis_tready == 0) @(posedge clk); 
        end
    endtask

    initial begin
        // Init
        clk = 0;
        rst = 1;
        s_axis_tdata = 0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        m_axis_tready = 0;

        // Reset
        #100;
        rst = 0;
        #100;

        // Enable Receiver
        m_axis_tready = 1;

        $display("--- Sending Input Packet (Source: RANDOM, Dest: RANDOM) ---");

        // --- INJECT PACKET WITH RANDOM DATA ---
        // We want to verify the FPGA overwrites this with the Hardcoded constants.
        
        // MACs (Random Junk)
        send_byte(8'hFF, 0); send_byte(8'hFF, 0); send_byte(8'hFF, 0); 
        send_byte(8'hFF, 0); send_byte(8'hFF, 0); send_byte(8'hFF, 0); // Dest
        send_byte(8'h11, 0); send_byte(8'h22, 0); send_byte(8'h33, 0); 
        send_byte(8'h44, 0); send_byte(8'h55, 0); send_byte(8'h66, 0); // Src

        // EtherType
        send_byte(8'h08, 0); send_byte(8'h00, 0);

        // IP Header (We'll send 20 bytes of dummy IP data)
        // ... (Ver/Len/Tos/TotalLen/ID/Flags/TTL/Proto/Checksum) ...
        repeat(12) send_byte(8'h00, 0); 
        
        // Src IP (Sending 1.2.3.4)
        send_byte(8'd1, 0); send_byte(8'd2, 0); send_byte(8'd3, 0); send_byte(8'd4, 0);
        // Dest IP (Sending 5.6.7.8)
        send_byte(8'd5, 0); send_byte(8'd6, 0); send_byte(8'd7, 0); send_byte(8'd8, 0);

        // UDP Header
        // Src Port (1111)
        send_byte(8'h11, 0); send_byte(8'h11, 0);
        // Dest Port (2222)
        send_byte(8'h22, 0); send_byte(8'h22, 0);
        // Len/Check
        send_byte(8'h00, 0); send_byte(8'h0C, 0);
        send_byte(8'h00, 0); send_byte(8'h00, 0);

        // Payload
        send_byte("H", 0); send_byte("E", 0); send_byte("L", 0); send_byte("L", 0); send_byte("O", 1);
        
        s_axis_tvalid = 0;
        
        $display("--- Packet Sent. Waiting for Reply ---");
        #2000;
        $finish;
    end
    
    // --- MONITOR OUTPUT ---
    // This block automatically checks if the output matches your Hardcoded Parameters
    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            
            // Print raw data
            //$display("Byte %0d: %h", out_byte_cnt, m_axis_tdata);

            // Check specific bytes for the Hardcoded values
            // (Adjust these hex values if you changed them in your Verilog module)
            
            case (out_byte_cnt)
                // Check Dest MAC (AA:BB:CC:DD:EE:FF)
                0: if (m_axis_tdata !== 8'hAA) $display("ERROR: Dest MAC Byte 0 Incorrect!");
                5: if (m_axis_tdata !== 8'hFF) $display("ERROR: Dest MAC Byte 5 Incorrect!");
                
                // Check Dest IP (192.168.1.128 -> C0.A8.01.80)
                30: if (m_axis_tdata !== 8'hC0) $display("ERROR: Dest IP Byte 0 Incorrect!"); 
                33: if (m_axis_tdata !== 8'h80) $display("ERROR: Dest IP Byte 3 Incorrect!");

                // Check Dest Port (55555 -> D903)
                36: if (m_axis_tdata !== 8'hD9) $display("ERROR: Dest Port High Incorrect!");
                37: if (m_axis_tdata !== 8'h03) $display("ERROR: Dest Port Low Incorrect!");
            endcase

            if (m_axis_tlast) begin
                $display("--- Frame Complete. If no errors appeared above, Test PASSED. ---");
                out_byte_cnt <= 0;
            end else begin
                out_byte_cnt <= out_byte_cnt + 1;
            end
        end
    end

endmodule