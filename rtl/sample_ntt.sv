module sample_ntt #(
    parameter int DWIDTH = 256, // Seed size in bits (32 bytes per AXI beat)
    parameter int KEEP_WIDTH = DWIDTH / 8 // Number of valid bytes per AXI beat
) (
    input  wire clk,
    input  wire rst,

    input  wire start,
    output logic done,

    // -- AXI4-Stream Signals Sink --
    input  wire [DWIDTH-1:0]     t_data_i,
    input  wire                  t_valid_i,
    input  wire                  t_last_i,
    input  wire [KEEP_WIDTH-1:0] t_keep_i,
    output logic                 t_ready_o,

    // -- AXI4-Stream Signals Source --
    output logic [15:0] t_data_o,
    output logic        t_valid_o,
    output logic        t_last_o,
    output logic [1:0]  t_keep_o,
    input  wire         t_ready_i
);

    parameter int Q = 3329; // Modulus for Kyber

    // ============================================================
    // SampleNTT (FIPS 203 / Kyber-style) streaming implementation
    // - Consumes bytes from SHAKE stream
    // - Processes 3 bytes at a time:
    //      d1 = b0 + 256*(b1 & 0x0F)
    //      d2 = (b1 >> 4) + 16*b2
    //   Accept candidate if < Q, emit as 16-bit coefficient.
    // ============================================================

    typedef enum logic [1:0] { S_IDLE, S_RUN, S_DONE } state_t;
    state_t state;

    // ----------------------------
    // Small byte FIFO (64 bytes)
    // ----------------------------
    logic [7:0]  fifo_mem [0:63];
    logic [6:0]  fifo_count;      // 0..64
    logic [5:0]  fifo_rd_ptr;     // circular
    logic [5:0]  fifo_wr_ptr;     // circular

    // Helper: count valid bytes in keep (for partial last-beat safety)
    function automatic int count_keep_bytes(input logic [KEEP_WIDTH-1:0] keep);
        int c;
        begin
            c = 0;
            for (int i = 0; i < KEEP_WIDTH; i++) begin
                if (keep[i]) c++;
            end
            return c;
        end
    endfunction

    // Helper: read FIFO byte at offset (0 = oldest)
    function automatic logic [7:0] fifo_peek(input int offset);
        logic [5:0] idx;
        begin
            idx = fifo_rd_ptr + offset[5:0];
            fifo_peek = fifo_mem[idx];
        end
    endfunction

    // ----------------------------
    // 2-entry output queue (skid)
    // ----------------------------
    typedef struct packed {
        logic [15:0] data;
        logic        last;
    } out_item_t;

    out_item_t out_q0, out_q1;
    logic      out_q0_valid, out_q1_valid;

    // How many free slots in the 2-deep queue?
    logic [1:0] free_slots;
    always_comb begin
        free_slots = 2;
        if (out_q0_valid) free_slots--;
        if (out_q1_valid) free_slots--;
    end

    // Present q0 on AXI source
    always_comb begin
        t_data_o  = out_q0.data;
        t_valid_o = out_q0_valid;
        t_last_o  = out_q0_valid ? out_q0.last : 1'b0;
        t_keep_o  = out_q0_valid ? 2'b11 : 2'b00;
    end

    // ----------------------------
    // Core counters
    // ----------------------------
    logic [8:0] coeff_count; // 0..256 (needs 9 bits)

    // ----------------------------
    // AXI sink ready (to Keccak)
    // - accept new 32B beat only if enough FIFO space
    // ----------------------------
    logic [6:0] fifo_space;
    always_comb begin
        fifo_space = 7'd64 - fifo_count;
        // We can accept up to 32 bytes per beat; be conservative and require 32B space
        t_ready_o = (state == S_RUN) && (fifo_space >= 7'd32);
    end

    // ============================================================
    // Rejection sampling step (peek 3 bytes)
    // ============================================================
    logic        have_3_bytes;
    logic [7:0]  b0, b1, b2;
    logic [11:0] d1, d2;
    logic        v1, v2;
    logic [1:0]  needed_slots;

    always_comb begin
        have_3_bytes = (fifo_count >= 7'd3);

        b0 = have_3_bytes ? fifo_peek(0) : 8'h00;
        b1 = have_3_bytes ? fifo_peek(1) : 8'h00;
        b2 = have_3_bytes ? fifo_peek(2) : 8'h00;

        d1 = {4'b0, b0} + (12'(b1[3:0]) << 8);      // b0 + 256*(b1 & 0x0F)
        d2 = (12'(b1[7:4])) + (12'(b2) << 4);       // (b1>>4) + 16*b2

        v1 = (d1 < Q);
        v2 = (d2 < Q);

        // Determine how many coefficients we would emit from this 3-byte chunk,
        // respecting the 256-coefficient limit.
        needed_slots = 2'd0;
        if (v1 && (coeff_count < 9'd256)) needed_slots++;
        if (v2 && (coeff_count + (v1 ? 9'd1 : 9'd0) < 9'd256)) needed_slots++;
    end

    // Pop 3 bytes (consume chunk) when we decide to process it
    logic do_process_chunk;

    always_comb begin
        // We only process when:
        // - running
        // - have 3 bytes available
        // - and we have enough output-queue space for the coeffs that will be emitted
        // This avoids needing to "half-consume" a chunk.
        do_process_chunk = (state == S_RUN)
                        && have_3_bytes
                        && (free_slots >= needed_slots)
                        && (coeff_count < 9'd256);
    end

    // ============================================================
    // Sequential logic
    // ============================================================
    integer k;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state         <= S_IDLE;
            done          <= 1'b0;

            fifo_count    <= 7'd0;
            fifo_rd_ptr   <= 6'd0;
            fifo_wr_ptr   <= 6'd0;

            out_q0_valid  <= 1'b0;
            out_q1_valid  <= 1'b0;
            out_q0        <= '0;
            out_q1        <= '0;

            coeff_count   <= 9'd0;
        end else begin
            done <= 1'b0;

            // ----------------------------
            // AXI source dequeue (when receiver ready)
            // ----------------------------
            if (out_q0_valid && t_ready_i) begin
                // shift q1 -> q0
                out_q0       <= out_q1;
                out_q0_valid <= out_q1_valid;
                out_q1_valid <= 1'b0;
            end

            // ----------------------------
            // FSM
            // ----------------------------
            case (state)
                S_IDLE: begin
                    // reset internal state on start
                    if (start) begin
                        fifo_count   <= 7'd0;
                        fifo_rd_ptr  <= 6'd0;
                        fifo_wr_ptr  <= 6'd0;

                        out_q0_valid <= 1'b0;
                        out_q1_valid <= 1'b0;
                        out_q0       <= '0;
                        out_q1       <= '0;

                        coeff_count  <= 9'd0;

                        state        <= S_RUN;
                    end
                end

                S_RUN: begin
                    // ----------------------------
                    // AXI sink enqueue (from Keccak)
                    // ----------------------------
                    if (t_valid_i && t_ready_o) begin
                        // Append valid bytes according to t_keep_i
                        // AXI convention: t_data_i is [DWIDTH-1:0]; treat as 32 bytes little-endian per lane order.
                        // We map byte i to t_data_i[8*i +: 8]
                        for (k = 0; k < KEEP_WIDTH; k++) begin
                            if (t_keep_i[k] && (fifo_count < 7'd64)) begin
                                fifo_mem[fifo_wr_ptr] <= t_data_i[8*k +: 8];
                                fifo_wr_ptr <= fifo_wr_ptr + 6'd1;
                                fifo_count  <= fifo_count + 7'd1;
                            end
                        end
                    end

                    // ----------------------------
                    // Process 3-byte chunk -> up to 2 coeffs
                    // ----------------------------
                    if (do_process_chunk) begin
                        // consume 3 bytes
                        fifo_rd_ptr <= fifo_rd_ptr + 6'd3;
                        fifo_count  <= fifo_count  - 7'd3;

                        // push outputs in order d1 then d2 if valid
                        // push into q0 if empty else q1
                        if (v1 && (coeff_count < 9'd256)) begin
                            out_item_t item1;
                            item1.data = {4'b0, d1}; // 12-bit -> 16-bit
                            item1.last = (coeff_count == 9'd255); // last when emitting 256th coeff
                            if (!out_q0_valid) begin
                                out_q0       <= item1;
                                out_q0_valid <= 1'b1;
                            end else begin
                                out_q1       <= item1;
                                out_q1_valid <= 1'b1;
                            end
                            coeff_count <= coeff_count + 9'd1;
                        end

                        // For d2, be careful: coeff_count may have updated above.
                        // Use a local computed "next_count" behavior via conditional checks:
                        // We'll recompute based on v1.
                        if (v2) begin
                            logic [8:0] base_count;
                            base_count = coeff_count + (v1 ? 9'd1 : 9'd0);
                            if (base_count < 9'd256) begin
                                out_item_t item2;
                                item2.data = {4'b0, d2};
                                item2.last = (base_count == 9'd255);
                                if (!out_q0_valid) begin
                                    out_q0       <= item2;
                                    out_q0_valid <= 1'b1;
                                end else if (!out_q1_valid) begin
                                    out_q1       <= item2;
                                    out_q1_valid <= 1'b1;
                                end
                                coeff_count <= base_count + 9'd1;
                            end
                        end
                    end

                    // ----------------------------
                    // Done condition: generated 256 coeffs AND output queue drained
                    // ----------------------------
                    if ((coeff_count >= 9'd256) && !out_q0_valid && !out_q1_valid) begin
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;   // 1-cycle pulse
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule