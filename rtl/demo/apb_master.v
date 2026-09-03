// Minimal synchronous APB master for the Genesys 2 demo (rtl/demo/).
// Drives rtl/ip/ascon_apb.v from a simple start/we/addr/wdata/rdata/
// done handshake -- one transaction per `start` pulse. Implements the
// real two-phase APB protocol (SETUP then ACCESS, `pready`-gated)
// rather than assuming ascon_apb's zero-wait-state behaviour, so this
// master would also work unmodified against a slave that stalls.
//
// `done` pulses for exactly one cycle when a transaction completes;
// `rdata`/`pslverr_latched` hold their value from that transaction
// until the next one completes.

module apb_master (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire        we,
    input  wire [7:0]  addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output reg         done,
    output reg         pslverr_latched,

    output reg         psel,
    output reg         penable,
    output reg         pwrite,
    output reg  [7:0]  paddr,
    output reg  [31:0] pwdata,
    input  wire [31:0] prdata,
    input  wire        pready,
    input  wire        pslverr
);

    localparam [1:0] S_IDLE   = 2'd0;
    localparam [1:0] S_SETUP  = 2'd1;
    localparam [1:0] S_ACCESS = 2'd2;

    reg [1:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            psel            <= 1'b0;
            penable         <= 1'b0;
            pwrite          <= 1'b0;
            paddr           <= 8'h0;
            pwdata          <= 32'h0;
            rdata           <= 32'h0;
            done            <= 1'b0;
            pslverr_latched <= 1'b0;
        end else begin
            done <= 1'b0; // default: single-cycle pulse

            case (state)
                S_IDLE: begin
                    if (start) begin
                        psel    <= 1'b1;
                        penable <= 1'b0;
                        pwrite  <= we;
                        paddr   <= addr;
                        pwdata  <= wdata;
                        state   <= S_SETUP;
                    end
                end

                S_SETUP: begin
                    penable <= 1'b1;
                    state   <= S_ACCESS;
                end

                S_ACCESS: begin
                    if (pready) begin
                        rdata           <= prdata;
                        pslverr_latched <= pslverr;
                        done            <= 1'b1;
                        psel            <= 1'b0;
                        penable         <= 1'b0;
                        state           <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
