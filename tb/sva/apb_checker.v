// Pure Verilog-2001 APB protocol checker -- no SystemVerilog assertions
// (Icarus does not support SVA, and rtl/ is Verilog-2001 only per
// CLAUDE.md, so tb/sva/ stays plain Verilog too). Wired up alongside
// the DUT as a passive monitor: every input here is also driven into
// ascon_apb, so this module never affects simulation results, only
// observes and flags protocol violations the instant they occur.
//
// Usage: instantiate in a testbench with the same pclk/presetn and
// APB bus signals the BFM drives into the DUT, then call
// report_summary() once at the end of the run (e.g. right before
// $finish) to print the final tally. violation_count can be read at
// any time (e.g. folded into a top-level PASSED/FAILED verdict).
//
// Rules checked (docs/spec.md section 6.2/7):
//   1. SETUP (psel && !penable) must be followed by ACCESS
//      (psel && penable) on the very next clock edge.
//   2. While an ACCESS phase is extended by wait states (pready was
//      low last cycle), paddr/pwdata/pwrite must not change.
//   3. penable must never be high while psel is low.
//   4. STATUS.tag_fail=1 implies STATUS.dout_valid=0 (docs/spec.md
//      9.5 -- no plaintext leak on tag failure), checked whenever a
//      STATUS read transfer completes.
//   5. Reading any KEY register (0x10..0x1C) must return prdata==0
//      (docs/spec.md 7 -- keys are write-only), checked whenever such
//      a read transfer completes.

`timescale 1ns/1ps

module apb_checker #(
    parameter ADDR_WIDTH = 8,
    parameter DATA_WIDTH = 32
) (
    input  wire                  pclk,
    input  wire                  presetn,

    input  wire                  psel,
    input  wire                  penable,
    input  wire                  pwrite,
    input  wire [ADDR_WIDTH-1:0] paddr,
    input  wire [DATA_WIDTH-1:0] pwdata,
    input  wire [DATA_WIDTH-1:0] prdata,
    input  wire                  pready,

    output wire [31:0]           violation_count
);

    // register map bits this checker needs to know about
    // (docs/spec.md section 7)
    localparam ADDR_STATUS = 8'h04;
    localparam ADDR_KEY0   = 8'h10;
    localparam ADDR_KEY1   = 8'h14;
    localparam ADDR_KEY2   = 8'h18;
    localparam ADDR_KEY3   = 8'h1C;

    localparam STATUS_DOUT_VALID_BIT = 2;
    localparam STATUS_TAG_FAIL_BIT   = 4;

    integer violations;
    initial violations = 0;
    assign violation_count = violations;

    wire is_key_addr = (paddr == ADDR_KEY0) || (paddr == ADDR_KEY1) ||
                        (paddr == ADDR_KEY2) || (paddr == ADDR_KEY3);

    // "previous cycle" trackers -- sampled at the end of every posedge
    // once presetn is high, so rule 1/2 (which describe a transition
    // between two consecutive cycles) have valid history to compare
    // against. `primed` is low for the first post-reset cycle, when
    // there is no valid previous-cycle sample yet.
    reg                  primed;
    reg                  setup_prev;       // psel && !penable, last cycle
    reg                  access_wait_prev; // psel && penable && !pready, last cycle
    reg [ADDR_WIDTH-1:0] paddr_prev;
    reg [DATA_WIDTH-1:0] pwdata_prev;
    reg                  pwrite_prev;

    always @(posedge pclk) begin
        if (!presetn) begin
            primed           <= 1'b0;
            setup_prev       <= 1'b0;
            access_wait_prev <= 1'b0;
            paddr_prev       <= {ADDR_WIDTH{1'b0}};
            pwdata_prev      <= {DATA_WIDTH{1'b0}};
            pwrite_prev      <= 1'b0;
        end else begin
            // ---- Rule 3: penable requires psel, every cycle ------------
            if (penable && !psel) begin
                violations = violations + 1;
                $display("APB_CHECKER VIOLATION @%0t: rule3 penable=1 while psel=0",
                          $time);
            end

            if (primed) begin
                // ---- Rule 1: SETUP must be followed by ACCESS ----------
                if (setup_prev && !(psel && penable)) begin
                    violations = violations + 1;
                    $display("APB_CHECKER VIOLATION @%0t: rule1 SETUP not followed by ACCESS (psel=%b penable=%b)",
                              $time, psel, penable);
                end

                // ---- Rule 2: stable paddr/pwdata/pwrite while waiting --
                if (access_wait_prev &&
                    ((paddr !== paddr_prev) || (pwdata !== pwdata_prev) ||
                     (pwrite !== pwrite_prev))) begin
                    violations = violations + 1;
                    $display("APB_CHECKER VIOLATION @%0t: rule2 signals changed during wait state (paddr %h->%h pwdata %h->%h pwrite %b->%b)",
                              $time, paddr_prev, paddr, pwdata_prev, pwdata,
                              pwrite_prev, pwrite);
                end
            end

            // ---- Rule 4: STATUS read completing this cycle -------------
            if (psel && penable && pready && !pwrite && (paddr == ADDR_STATUS)) begin
                if (prdata[STATUS_TAG_FAIL_BIT] && prdata[STATUS_DOUT_VALID_BIT]) begin
                    violations = violations + 1;
                    $display("APB_CHECKER VIOLATION @%0t: rule4 tag_fail=1 with dout_valid=1 (STATUS=%h)",
                              $time, prdata);
                end
            end

            // ---- Rule 5: KEY read completing this cycle ----------------
            if (psel && penable && pready && !pwrite && is_key_addr) begin
                if (prdata !== {DATA_WIDTH{1'b0}}) begin
                    violations = violations + 1;
                    $display("APB_CHECKER VIOLATION @%0t: rule5 KEY read returned nonzero prdata=%h (addr=%h)",
                              $time, prdata, paddr);
                end
            end

            primed           <= 1'b1;
            setup_prev       <= psel && !penable;
            access_wait_prev <= psel && penable && !pready;
            paddr_prev       <= paddr;
            pwdata_prev      <= pwdata;
            pwrite_prev      <= pwrite;
        end
    end

    task report_summary;
        begin
            $display("APB_CHECKER SUMMARY: %0d violation(s) total", violations);
        end
    endtask

endmodule
