module mem_serializer #(
    parameter CONFIG_MEM  = "config.mem",
    parameter MEM_WIDTH   = 24,
    parameter WORD_NUMBER = 326,
    parameter DATA_WIDTH  = 8,
    parameter CLK_FREQ    = 125_000_000
) (
    input  wire                  clk_i,
    input  wire                  arstn_i,
    input  wire                  ack_i,
    output reg  [DATA_WIDTH-1:0] data_o
);

    localparam PERIOD_NS  = (1/CLK_FREQ) * 1_000_000_000;
    localparam PAUSE_NS   = (300 * 1_000_000)/PERIOD_NS;  // delay 300 msec(300_000_000 ns) and 8 ns period of clock cycle
    localparam CYCLES     = MEM_WIDTH/DATA_WIDTH;         // need 3 cycles to transmit 24 bit for 8 bit data output and pause between every byte
    localparam SLAVE_ADDR = 8'b11101_00_0;                // [6:0] 1110100 - addr, [7] - write/read bit

    localparam [1:0] IDLE  = 2'b00,
                     DATA  = 2'b01,
                     PAUSE = 2'b10,
                     INDEX = 2'b11;

    reg [$clog2(CYCLES)-1:0]      cycles_cnt;
    reg [MEM_WIDTH-1:0]           tmp;
    reg [$clog2(PAUSE_NS)-1:0]    pause_cnt;
    reg [$clog2(WORD_NUMBER)-1:0] mem_index;
    reg [1:0]                     state;
    reg                           flag;

    reg [MEM_WIDTH-1:0] mem [0:WORD_NUMBER-1]; // [23:8] - addr, [7:0] - data

    initial $readmemh(CONFIG_MEM, mem);

    always @(posedge clk_i or negedge arstn_i) begin
        if (~arstn_i) begin
            mem_index  <= 0;
            pause_cnt  <= 0;
            cycles_cnt <= 0;
            tmp        <= 0;
            flag       <= 1;
            state      <= INIT;
        end else begin
            case (state)
                IDLE: begin
                    state  <= PAUSE;
                    tmp    <= mem[mem_index];
                    if (flag) data_o <= SLAVE_ADDR;
                end
                DATA: if (ack_i) begin
                    data_o <= tmp[cycles_cnt*DATA_WIDTH +: DATA_WIDTH];
                    flag   <= 0;
                    if (cycles_cnt == CYCLES - 1) begin
                        cycles_cnt <= 0;
                        state      <= INDEX;
                    end else begin
                        cycles_cnt <= cycles_cnt + 1;
                        state      <= PAUSE;
                    end
                end else state <= DATA;
                PAUSE: if (pause_cnt == PAUSE_NS) begin
                    pause_cnt <= 0;
                    state     <= DATA;
                end else begin
                    pause_cnt <= pause_cnt + 1;
                    state     <= PAUSE;
                end
                INDEX: if (mem_index == WORD_NUMBER - 1) begin
                    mem_index <= 0;
                    flag      <= 1;
                    state     <= IDLE;
                end else begin
                    mem_index <= mem_index + 1;
                    state     <= IDLE;
                end
                default: state <= INIT;
            endcase
        end
    end

    `ifdef COCOTB_SIM
        initial begin
            $dumpfile ("mem_serializer.vcd");
            $dumpvars (0, mem_serializer);
            #1;
        end
    `endif

endmodule
