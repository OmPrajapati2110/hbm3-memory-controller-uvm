"""UVM agents: one active client agent per client port, one passive command
bus agent. Items flow sequencer -> driver -> BFM; monitors publish observed
transactions on analysis ports."""
from pyuvm import (uvm_sequence_item, uvm_sequencer, uvm_driver, uvm_monitor,
                   uvm_agent, uvm_analysis_port, ConfigDB)

from mc_bfm import HarnessBfm
from mc_common import rand_data


class MemReqItem(uvm_sequence_item):
    """Client request. The driver assigns the transaction ID from a free pool
    so that a sequence can never reuse an outstanding ID."""

    def __init__(self, name="mem_req"):
        super().__init__(name)
        self.we = 0
        self.addr = 0
        self.wdata = 0
        self.idle = 0          # cycles to wait before presenting the request
        self.id = None         # filled in by the driver

    def randomize_data(self):
        self.wdata = rand_data() if self.we else 0

    def __str__(self):
        k = "WR" if self.we else "RD"
        return f"{k} addr=0x{self.addr:07x} id={self.id} idle={self.idle}"


class ClientDriver(uvm_driver):
    def build_phase(self):
        self.client = ConfigDB().get(self, "", "client")
        self.bfm = HarnessBfm()

    async def run_phase(self):
        while True:
            item = await self.seq_item_port.get_next_item()
            item.id = await self.bfm.alloc_id(self.client)
            await self.bfm.send_req(self.client, item.we, item.addr, item.wdata,
                                    item.id, item.idle)
            self.seq_item_port.item_done()


class ClientAgent(uvm_agent):
    """Active agent. Monitoring for all clients is centralised in
    ClientBusMonitor because the BFM samples the packed vectors once."""

    def build_phase(self):
        self.client = ConfigDB().get(self, "", "client")
        ConfigDB().set(self, "*", "client", self.client)
        self.seqr = uvm_sequencer("seqr", self)
        self.driver = ClientDriver("driver", self)

    def connect_phase(self):
        self.driver.seq_item_port.connect(self.seqr.seq_item_export)


class HarnessMonitor(uvm_monitor):
    """Passive monitor for the whole harness: accepted client requests,
    delivered responses and the HBM row/column command buses. A single
    monitor keeps every subscriber in exact cycle order."""

    def build_phase(self):
        self.req_ap = uvm_analysis_port("req_ap", self)
        self.rsp_ap = uvm_analysis_port("rsp_ap", self)
        self.cmd_ap = uvm_analysis_port("cmd_ap", self)
        self.bfm = HarnessBfm()

    async def run_phase(self):
        while True:
            kind, obs = await self.bfm.mon_q.get()
            if kind == "req":
                self.req_ap.write(obs)
            elif kind == "rsp":
                self.rsp_ap.write(obs)
                self.bfm.release_id(obs.client, obs.id)
            else:
                self.cmd_ap.write(obs)


class BusAgent(uvm_agent):
    """Passive agent wrapping HarnessMonitor."""

    def build_phase(self):
        self.monitor = HarnessMonitor("monitor", self)
