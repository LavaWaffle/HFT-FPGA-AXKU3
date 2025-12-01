`include "order_defines.v"

module heap_manager (
    input wire clk,
    input wire rst_n,

    // Command Interface
    input wire [1:0] cmd,
    input wire [31:0] data_in,
    
    // Status Outputs
    output reg [31:0] root_out, // Always the BEST price
    output reg [9:0] count,
    output reg full,
    output reg empty,
    output reg busy,
    output reg done,

    // BRAM Interface
    output reg  we,
    output reg  [9:0] addr,
    output reg  [31:0] wdata,
    input  wire [31:0] rdata
);

    // --- State Encoding ---
    localparam IDLE             = 0;
    
    // Push States (Bubble Up)
    localparam PUSH_WRITE       = 1;
    localparam PUSH_READ_PARENT = 2;
    localparam PUSH_WAIT_PARENT = 3;
    localparam PUSH_COMPARE     = 4;
    localparam PUSH_MOVE_PARENT = 5; // Move Parent Down
    
    // Pop States (Sift Down)
    localparam POP_READ_LAST    = 6;
    localparam POP_WAIT_LAST    = 7;
    localparam POP_SETUP_ROOT   = 8; // Move Last to Holding, Decr Count
    localparam SIFT_CHECK_KIDS  = 9; // Do children exist?
    localparam SIFT_READ_LEFT   = 10;
    localparam SIFT_WAIT_LEFT   = 11;
    localparam SIFT_READ_RIGHT  = 12;
    localparam SIFT_WAIT_RIGHT  = 13;
    localparam SIFT_COMPARE     = 14; // Compare Kids vs Holding
    localparam SIFT_MOVE_CHILD  = 15; // Move Child Up
    localparam SIFT_WRITE_FINAL = 16; // Write Holding to final spot
    
    // Update State (Partial Fill)
    localparam UPDATE_WRITE     = 17;

    localparam FINISH           = 18;

    reg [4:0] state; // Expanded to 5 bits

    // --- Internal Storage ---
    reg [9:0] curr_idx;
    reg [9:0] target_idx; 
    reg [31:0] holding_reg;     // The node we are moving (Bubble/Sift)
    
    // Sift Down Specific Registers
    reg [31:0] left_val;
    reg [31:0] right_val;
    reg        right_exists;

    // Configuration Parameter
    parameter HEAP_TYPE = `TYPE_BID; 

    // --- Combinational Logic for Comparisons ---
    reg swap_up_needed;
    reg swap_down_needed;
    reg left_is_better; // True if Left Child is "more preferred" than Right Child
    reg use_right_child; // Decision signal

    always @(*) begin
        // 1. Bubble Up Logic (Child vs Parent)
        // Parent is in 'rdata', Child is 'holding_reg'
        swap_up_needed = 0;
        if (HEAP_TYPE == `TYPE_BID) begin
            if (`PRICE(holding_reg) > `PRICE(rdata)) swap_up_needed = 1;
        end else begin
            if (`PRICE(holding_reg) < `PRICE(rdata)) swap_up_needed = 1;
        end

        // 2. Sift Down Logic (Child vs Child)
        // Determines which child is the "Target" to potentially swap with
        left_is_better = 0;
        if (HEAP_TYPE == `TYPE_BID) begin
            // Max Heap: Left is better if Left > Right
            if (`PRICE(left_val) >= `PRICE(right_val)) left_is_better = 1;
        end else begin
            // Min Heap: Left is better if Left < Right
            if (`PRICE(left_val) <= `PRICE(right_val)) left_is_better = 1;
        end

        // 3. Swap Decision (Holding vs Best Child)
        // If we only have a left child, use left. If both, use the "better" one.
        // 'use_right_child' tells the state machine which index to swap with.
        use_right_child = (right_exists && !left_is_better);

        swap_down_needed = 0;
        // Compare Holding vs The Chosen Child
        if (use_right_child) begin
            // Compare vs Right
            if (HEAP_TYPE == `TYPE_BID) begin
                if (`PRICE(right_val) > `PRICE(holding_reg)) swap_down_needed = 1;
            end else begin
                if (`PRICE(right_val) < `PRICE(holding_reg)) swap_down_needed = 1;
            end
        end else begin
            // Compare vs Left
            if (HEAP_TYPE == `TYPE_BID) begin
                if (`PRICE(left_val) > `PRICE(holding_reg)) swap_down_needed = 1;
            end else begin
                if (`PRICE(left_val) < `PRICE(holding_reg)) swap_down_needed = 1;
            end
        end
    end

    // --- Main Sequential Logic ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            count <= 0;
            full <= 0;
            empty <= 1;
            busy <= 0;
            done <= 0;
            we <= 0;
            // Initialize root_out to 0 or Max depending on type? 
            // For safety, 0. Logic relies on 'empty' flag.
            root_out <= 0; 
        end else begin
            case (state)
                IDLE: begin
                    done <= 0;
                    we <= 0;
                    
                    // --- PUSH COMMAND ---
                    if (cmd == `CMD_PUSH && !full) begin
                        busy <= 1;
                        curr_idx <= count + 1; // 1-based index
                        holding_reg <= data_in;
                        state <= PUSH_WRITE;
                    end 
                    // --- POP COMMAND ---
                    else if (cmd == `CMD_POP && !empty) begin
                        busy <= 1;
                        // Start by fetching the Last Element
                        addr <= count; 
                        state <= POP_READ_LAST;
                    end
                    // --- UPDATE COMMAND ---
                    else if (cmd == `CMD_UPDATE && !empty) begin
                        busy <= 1;
                        // Just overwrite root with new quantity
                        curr_idx <= 1;
                        holding_reg <= data_in; // This has new quantity
                        state <= UPDATE_WRITE;
                    end
                end

                // ==========================================
                // PATH 1: PUSH (Bubble Up)
                // ==========================================
                PUSH_WRITE: begin
                    // Optimistic write: Write holding reg to current spot.
                    // If we swap later, we overwrite it.
                    we <= 1;
                    addr <= curr_idx;
                    wdata <= holding_reg;
                    
                    // Update Size if this is the first write of the sequence
                    if (curr_idx == count + 1) begin
                        count <= count + 1;
                        empty <= 0;
                        if (count == 1022) full <= 1;
                    end
                    
                    // If at Root, we are done
                    if (curr_idx == 1) begin
                        root_out <= holding_reg; // Update Cache
                        state <= FINISH;
                    end else begin
                        state <= PUSH_READ_PARENT;
                    end
                end

                PUSH_READ_PARENT: begin
                    we <= 0;
                    target_idx <= curr_idx >> 1; // Parent = i / 2
                    addr <= curr_idx >> 1;
                    state <= PUSH_WAIT_PARENT;
                end

                PUSH_WAIT_PARENT: state <= PUSH_COMPARE;

                PUSH_COMPARE: begin
                    // rdata = Parent. holding_reg = Child.
                    if (swap_up_needed) begin
                        // Parent is worse. Move Parent DOWN to Child's spot.
                        we <= 1;
                        addr <= curr_idx;
                        wdata <= rdata;
                        state <= PUSH_MOVE_PARENT;
                    end else begin
                        // Parent is better. We found our spot.
                        state <= FINISH;
                    end
                end

                PUSH_MOVE_PARENT: begin
                    // We moved parent down. Now move 'curr_idx' up to Parent's old spot.
                    we <= 0;
                    curr_idx <= target_idx;
                    // Loop back to write our holding reg there (and check *its* parent)
                    state <= PUSH_WRITE;
                end


                // ==========================================
                // PATH 2: POP (Sift Down)
                // ==========================================
                POP_READ_LAST: state <= POP_WAIT_LAST;
                POP_WAIT_LAST: state <= POP_SETUP_ROOT;

                POP_SETUP_ROOT: begin
                    // rdata is the Last Element.
                    holding_reg <= rdata; // We must sink this node down
                    
                    // Clean up
                    we    <= 1;
                    addr  <= count;
                    wdata <= 32'd0;
                    
                    // Decrease count
                    count <= count - 1;
                    if (count == 1) begin
                        empty <= 1; // We just removed the only item
                        // If empty, no need to sift. Just zero out root?
                        // Or just mark empty.
                        root_out <= 0;
                        state <= FINISH;
                    end else begin
                        // Start Sifting from Root
                        curr_idx <= 1;
                        state <= SIFT_CHECK_KIDS;
                    end
                end

                SIFT_CHECK_KIDS: begin
                    we <= 0;
                    // Check if Left Child exists (2*i <= count)
                    // Note: 'count' is already decremented.
                    if ((curr_idx << 1) <= count) begin
                        // Left Child exists. Read it.
                        addr <= (curr_idx << 1);
                        state <= SIFT_READ_LEFT;
                    end else begin
                        // No children. We are a leaf.
                        state <= SIFT_WRITE_FINAL;
                    end
                end

                SIFT_READ_LEFT: state <= SIFT_WAIT_LEFT;
                SIFT_WAIT_LEFT: begin
                    left_val <= rdata;
                    // Check Right Child ((2*i)+1 <= count)
                    if (((curr_idx << 1) + 1) <= count) begin
                        right_exists <= 1;
                        addr <= ((curr_idx << 1) + 1);
                        state <= SIFT_READ_RIGHT;
                    end else begin
                        right_exists <= 0;
                        state <= SIFT_COMPARE;
                    end
                end

                SIFT_READ_RIGHT: state <= SIFT_WAIT_RIGHT;
                SIFT_WAIT_RIGHT: begin
                    right_val <= rdata;
                    state <= SIFT_COMPARE;
                end

                SIFT_COMPARE: begin
                    // Combinational logic 'swap_down_needed' calculates result
                    if (swap_down_needed) begin
                        // We must swap with one of the children
                        if (use_right_child) begin
                            target_idx <= (curr_idx << 1) + 1;
                            wdata <= right_val; // Move Right Child UP
                        end else begin
                            target_idx <= (curr_idx << 1);
                            wdata <= left_val;  // Move Left Child UP
                        end
                        // Write Child to Current Spot
                        we <= 1;
                        addr <= curr_idx;
                        state <= SIFT_MOVE_CHILD;
                    end else begin
                        // No swap needed. We are larger/smaller than both kids.
                        state <= SIFT_WRITE_FINAL;
                    end
                end

                SIFT_MOVE_CHILD: begin
                    // We wrote the child up. Now move our index down.
                    we <= 0;
                    curr_idx <= target_idx;
                    // Loop back to check the new children
                    state <= SIFT_CHECK_KIDS;
                end

                SIFT_WRITE_FINAL: begin
                    // Write the 'holding_reg' (the node we sank) into its final resting place
                    we <= 1;
                    addr <= curr_idx;
                    wdata <= holding_reg;
                    
                    // If we landed at root (rare, but possible if heap was size 1), update cache
                    if (curr_idx == 1) root_out <= holding_reg;
                    
                    // Wait 1 cycle for write, then update Root Cache if we aren't at root?
                    // Actually, if we just modified BRAM, root_out (cache) might be stale if we swapped root.
                    // We must ensure root_out is valid.
                    // If we swapped root (curr_idx=1 at start), the New Child is at Root.
                    // But we don't have a read path to refresh 'root_out' easily here.
                    // TRICK: The logic relies on BRAM, but 'root_out' is an output port.
                    // We need to update 'root_out' whenever we write to addr 1.
                    if (curr_idx == 1) root_out <= holding_reg;
                    // If we swapped earlier, we wrote a child to addr 1. We should have updated root_out then.
                    // Let's add a dedicated fix:
                    // In SIFT_MOVE_CHILD: if (curr_idx == 1) root_out <= wdata;
                    state <= FINISH;
                end

                // ==========================================
                // PATH 3: UPDATE (Partial Fill)
                // ==========================================
                UPDATE_WRITE: begin
                    we <= 1;
                    addr <= 1; // Root
                    wdata <= holding_reg; // New quantity
                    root_out <= holding_reg; // Update cache
                    state <= FINISH;
                end

                FINISH: begin
                    we <= 0;
                    busy <= 0;
                    done <= 1;
                    state <= IDLE;
                end

            endcase
            
            // --- Cache Fix Patch ---
            // If we ever write to address 1 (Root), we MUST update the output register `root_out`
            // This ensures the Engine sees the new Best Price immediately.
            if (we && addr == 1) begin
                root_out <= wdata;
            end
        end
    end

endmodule