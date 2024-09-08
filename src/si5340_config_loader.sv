// Status: Doing

`include "cfg_pkg.svh"

import cfg_pkg::*;

module si5340_config_loader #(
    parameter CONFIG_MEM  = "config.mem"
) (
    input logic clk_i,
    input logic arstn_i,
    input logic load,
    input logic write,

    // inout wire sda, // SCL-line
    // inout wire scl  // SDA-line

    // I2C
    input  scl_pad_i,    // SCL-line input
    output scl_pad_o,    // SCL-line output (always 1'b0)
    output scl_padoen_o, // SCL-line output enable (active low)
    input  sda_pad_i,    // SDA-line input
    output sda_pad_o,    // SDA-line output (always 1'b0)
    output sda_padoen_o, // SDA-line output enable (active low)


    i2_ctrl_if.master m_i2_ctrl_if
);

    // wire scl_pad_i;    // SCL-line input
    // wire scl_pad_o;    // SCL-line output (always 1'b0)
    // wire scl_padoen_o; // SCL-line output enable (active low)
    // wire sda_pad_i;    // SDA-line input
    // wire sda_pad_o;    // SDA-line output (always 1'b0)
    // wire sda_padoen_o; // SDA-line output enable (active low)

    // assign scl_pad_i = scl;
    // assign sda_pad_i = sda;
    // assign scl       = scl_padoen_o ? 1'bz : scl_pad_o;
    // assign sda       = sda_padoen_o ? 1'bz : sda_pad_o;

    i2c_master_byte i2c_inst (
        .clk     (clk_i               ),
        .rst     (0                   ),
        .nReset  (arstn_i             ),
        .ena     (1                   ),
        .clk_cnt (CLK_CNT             ),
        .start   (m_i2_ctrl_if.start  ),
        .stop    (m_i2_ctrl_if.stop   ),
        .read    (m_i2_ctrl_if.read   ),
        .write   (m_i2_ctrl_if.write  ),
        .ack_in  (m_i2_ctrl_if.ack_in ),
        .din     (m_i2_ctrl_if.din    ),
        .dout    (m_i2_ctrl_if.dout   ),
        .cmd_ack (m_i2_ctrl_if.cmd_ack),
        .scl_i   (scl_pad_i           ),
        .scl_o   (scl_pad_o           ),
        .sda_i   (sda_pad_i           ),
        .sda_o   (sda_pad_o           ),
        .scl_oen (scl_padoen_o        ),
        .sda_oen (sda_padoen_o        )
    );

    localparam QUEUE_LEN = 3;

    struct packed {
        logic [DATA_WIDTH-1:0] data;
        r_w                    rw;
        logic                  start;
        logic                  stop;
    } queue [QUEUE_LEN-1:0];

    enum logic [3:0] {
        IDLE        = 3'b000,
        CYCLES      = 3'b001,
        PAUSE       = 3'b010,
        MEM_INDEX   = 3'b011,
        ACK         = 3'b100,
        STOP        = 3'b101,
        WAIT_ACK    = 3'b110,
        QUEUE_INDEX = 3'b111
    } state;

    logic [$clog2(CYCLES)-1:0     ] cycles_cnt;
    logic [$clog2(PAUSE_NS)-1:0   ] pause_cnt;
    logic [$clog2(WORD_NUMBER)-1:0] mem_index;
    logic [$clog2(QUEUE_LEN)-1:0  ] queue_index;

    logic [MEM_WIDTH-1:0] mem [0:WORD_NUMBER-1]; // [23:8] - addr, [7:0] - data

    initial $readmemh(CONFIG_MEM, mem);

    always_ff @(posedge clk_i or negedge arstn_i) begin
        if (~arstn_i) begin
            mem_index   <= 0;
            pause_cnt   <= 0;
            queue_index <= 0;
            queue       <= 0;
            cycles_cnt  <= CYCLES - 1;
            state       <= IDLE;
        end else begin
            case (state)
                IDLE: if (load) state <= ACK;
                CYCLES: if (m_i2_ctrl_if.cmd_ack) begin
                    if (queue_index == 0) state <= QUEUE_INDEX;
                    else if (cycles_cnt == 1) begin 
                        cycles_cnt <= cycles_cnt - 1;
                        state      <= QUEUE_INDEX;
                    end else if (cycles_cnt == 0) begin
                        cycles_cnt <= CYCLES - 1;
                        state      <= MEM_INDEX;
                    end else begin
                        cycles_cnt <= cycles_cnt - 1;
                        state      <= PAUSE;
                    end
                end else if (queue[queue_index].stop) state <= STOP;
                else state <= CYCLES;
                PAUSE: if (pause_cnt == PAUSE_NS) begin
                    pause_cnt <= 0;
                    state     <= ACK;
                end else begin
                    pause_cnt <= pause_cnt + 1;
                    state     <= PAUSE;
                end
                MEM_INDEX: if (mem_index == WORD_NUMBER - 1) begin
                    mem_index <= 0;
                    state     <= QUEUE_INDEX;
                end else begin
                    mem_index <= mem_index + 1;
                    state     <= ACK;
                end
                ACK: state <= CYCLES;
                STOP: state <= WAIT_ACK;
                WAIT_ACK: if (m_i2_ctrl_if.cmd_ack) state <= QUEUE_INDEX;
                else state <= WAIT_ACK;
                QUEUE_INDEX: if (queue_index == QUEUE_LEN - 1) begin 
                    queue_index <= 0;
                    state       <= IDLE;
                end else begin
                    queue_index <= queue_index + 1;
                    state       <= PAUSE;
                end
                default: state <= IDLE;
            endcase
        end
    end

    always_comb begin
        m_i2_ctrl_if.din    = queue[queue_index].data;
        m_i2_ctrl_if.ack_in = (state == ACK || state == STOP) 1 ? : 0;
        m_i2_ctrl_if.start  = (state == ACK && queue[queue_index].start) 1 ? : 0;
        m_i2_ctrl_if.stop   = (state == STOP && queue[queue_index].stop) 1 ? : 0;
        m_i2_ctrl_if.read   = (state == ACK && queue[queue_index].rw == READ) 1 ? : 0;
        m_i2_ctrl_if.write  = (state == ACK && queue[queue_index].rw == WRITE) 1 ? : 0;
    end

    always_ff @(posedge clk_i) begin
        if (state == IDLE && load) begin
            if (write) begin // Write
                queue[0] <= {{SLAVE_ADDR, WRITE}, WRITE, 1, 0};
                queue[1] <= {mem[mem_index][cycles_cnt*DATA_WIDTH +: DATA_WIDTH], WRITE, 0, 0};
                queue[2] <= {mem[mem_index][cycles_cnt*DATA_WIDTH +: DATA_WIDTH], WRITE, 0, 1};
            end else begin // Read
                queue[0] <= {{SLAVE_ADDR, WRITE}, WRITE, 1, 0};
                queue[1] <= {mem[mem_index][cycles_cnt*DATA_WIDTH +: DATA_WIDTH], WRITE, 0, 0};
                queue[2] <= {mem[mem_index][cycles_cnt*DATA_WIDTH +: DATA_WIDTH], READ, 0, 1};
            end
        end
    end

    `ifdef COCOTB_SIM
        initial begin
            $dumpfile ("si5340_config_loader.vcd");
            $dumpvars (0, si5340_config_loader);
            #1;
        end
    `endif

endmodule
