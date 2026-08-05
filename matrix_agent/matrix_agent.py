#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
"""matrix_agent: sustain an all-to-all traffic matrix indefinitely.

One agent runs on every host. Each agent reads a shared traffic-matrix
CSV, sends to every peer at that pair's prescribed rate (paced, not
saturating), receives from every peer, and appends per-flow achieved
rates to a report CSV every interval. Receiver-side counters are the
ground truth: under congestion, sender-side numbers only show what TCP
queued, not what the fabric delivered.

Pacing is belt-and-braces: an application-level token bucket bounds the
rate everywhere, and on Linux SO_MAX_PACING_RATE is additionally set so
the kernel smooths the flow to a precise wire rate (best with the `fq`
qdisc: `tc qdisc replace dev <nic> root fq`).

Subcommands:
  gen        build a uniform matrix from a server list
  check      admissibility: row/column sums vs NIC capacity
  run        the agent itself (sender + receiver + reporter)
  hosts      list the hosts a matrix names (name addr port per line)
  summarize  aggregate report CSVs into a deficit summary

Matrix format: a grid CSV. Header row and first column carry host
tokens of the form  name[=addr[:port]]  (addr defaults to the name,
port to 5220). Bare IPs are fine as tokens ('10.0.0.7', or
'10.0.0.7:5299' with a port) -- the address doubles as the name, and
`run` then identifies its own row by matching the matrix addresses
against local interface addresses, no --hostname needed. Cells are
target rates in Mbit/s; empty or 0 means no flow; the diagonal is
ignored.

Traffic can be pinned to one NIC with --bind SPEC (or $IPERF_BIND),
using the same semantics as iperf-orchestrator's --bind: the spec is
substring-matched against `ip -o -4 addr show`, so it accepts an
interface name or an address.

Python 3.6+, stdlib only.
"""

import argparse
import csv
import os
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

MAGIC = b"MXA1"
RMAGIC = b"MXR1"              # request/response mode: reply datagrams
DEFAULT_PORT = 5220
MAX_CHUNK = 256 * 1024        # TCP write size for high-rate flows
UDP_PAYLOAD = 1400            # keep under typical 1500 MTU
RECONNECT_MIN, RECONNECT_MAX = 1.0, 15.0

_SO_MAX_PACING_RATE = getattr(socket, "SO_MAX_PACING_RATE", 47)  # Linux value


# ---------------------------------------------------------------------------
# Matrix parsing
# ---------------------------------------------------------------------------

def parse_token(tok):
    """'name[=addr[:port]]' -> (name, addr, port).

    Bare IPs work as host tokens ('10.0.0.7' or '10.0.0.7:5299'); for a
    bare token with a port, the name is the address without the port.
    """
    tok = tok.strip()
    bare = "=" not in tok
    if bare:
        name = addr = tok
    else:
        name, addr = tok.split("=", 1)
    port = DEFAULT_PORT
    if ":" in addr:
        addr, p = addr.rsplit(":", 1)
        port = int(p)
        if bare:
            name = addr
    return name, addr, port


def load_matrix(path, overrides=None):
    """Return (hosts, endpoints, rates).

    hosts:     ordered list of host names
    endpoints: name -> (addr, port)
    rates:     (src, dst) -> mbps (float, only entries > 0)
    """
    with open(path, newline="") as f:
        rows = [r for r in csv.reader(f) if r and any(c.strip() for c in r)]
    if len(rows) < 2:
        raise SystemExit("matrix %s: need a header row and at least one data row" % path)

    hosts, endpoints = [], {}
    for tok in rows[0][1:]:
        if not tok.strip():
            continue
        name, addr, port = parse_token(tok)
        hosts.append(name)
        endpoints[name] = (addr, port)

    rates = {}
    for row in rows[1:]:
        sname, _, _ = parse_token(row[0])
        if sname not in endpoints:
            raise SystemExit("matrix %s: row host %r not in header" % (path, sname))
        for i, cell in enumerate(row[1:len(hosts) + 1]):
            cell = cell.strip()
            if not cell:
                continue
            mbps = float(cell)
            dname = hosts[i]
            if mbps > 0 and sname != dname:
                rates[(sname, dname)] = mbps

    for ov in overrides or []:
        name, addr, port = parse_token(ov)
        if name in endpoints:
            endpoints[name] = (addr, port)
    return hosts, endpoints, rates


def _is_local_ipv4(addr):
    # True iff addr is an IPv4 literal assigned to a local interface --
    # probed by binding, which needs no privileges and no `ip` binary.
    try:
        socket.inet_aton(addr)
    except OSError:
        return False
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind((addr, 0))
        return True
    except OSError:
        return False
    finally:
        s.close()


def resolve_self(hosts, endpoints, override):
    if override:
        if override in hosts:
            return override
        raise SystemExit("--hostname %r not in matrix (hosts: %s)" % (override, ", ".join(hosts)))
    full = socket.gethostname()
    for cand in (full, full.split(".")[0]):
        if cand in hosts:
            return cand
    # IP-based matrices: this host is the row whose address is one of
    # our own interface addresses.
    local = [h for h in hosts if _is_local_ipv4(endpoints[h][0])]
    if len(local) == 1:
        return local[0]
    if len(local) > 1:
        raise SystemExit(
            "multiple matrix hosts are local addresses (%s); pass --hostname"
            % ", ".join(local))
    raise SystemExit(
        "hostname %r not found in matrix and no matrix address is local; "
        "pass --hostname. Hosts: %s" % (full, ", ".join(hosts)))


def resolve_bind(spec):
    """Resolve --bind exactly like iperf-orchestrator: the spec is a
    substring matched against `ip -o -4 addr show` output (so it matches
    an interface name OR an address); the first matching line's IPv4
    wins. Returns (iface, ip)."""
    try:
        out = subprocess.check_output(["ip", "-o", "-4", "addr", "show"],
                                      stderr=subprocess.DEVNULL).decode()
    except (OSError, subprocess.CalledProcessError):
        raise SystemExit("--bind %r: `ip -o -4 addr show` failed; is iproute2 installed?" % spec)
    for line in out.splitlines():
        if spec in line:
            parts = line.split()
            if len(parts) >= 4:
                return parts[1], parts[3].split("/")[0]
    raise SystemExit("--bind %r: no interface matched" % spec)


# ---------------------------------------------------------------------------
# Sender
# ---------------------------------------------------------------------------

class Flow(object):
    """One paced sender flow: this host -> one destination."""

    def __init__(self, me, dst, addr, port, mbps, proto, tuning):
        self.me, self.dst, self.addr, self.port = me, dst, addr, port
        self.proto = proto
        self.tuning = tuning
        self.mbps = mbps          # mutable: reload updates it in place
        self.bytes_sent = 0       # cumulative, guarded by lock
        self.pkts_sent = 0        # UDP: datagrams sent
        self.resp_pkts = 0        # UDP: reply datagrams received back
        self.resp_bytes = 0
        self.rtt_sum = 0.0        # sampled request->reply round trips
        self.rtt_n = 0
        self.reconnects = 0
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True,
                                       name="tx-%s" % dst)

    def start(self):
        self.thread.start()

    def _apply_kernel_pacing(self, sock, bps):
        # Best-effort: absent on non-Linux, and harmless to skip because
        # the token bucket below still bounds the average rate.
        # The kernel takes a u32 of bytes/sec; pack it explicitly. A bare
        # int above 2**31-1 (rates over ~17 Gbps) makes CPython retry the
        # argument as a buffer and raise TypeError, killing the flow.
        try:
            val = struct.pack("=I", min(int(bps), 0xFFFFFFFF))
            sock.setsockopt(socket.SOL_SOCKET, _SO_MAX_PACING_RATE, val)
        except OSError:
            pass

    def _chunk_for(self, bps):
        # Fixed write size when requested; otherwise aim for ~10
        # writes/sec so low-rate flows aren't lumpy and high-rate flows
        # aren't syscall-bound.
        if self.tuning["chunk"]:
            return self.tuning["chunk"]
        return max(4096, min(MAX_CHUNK, int(bps / 10)))

    def _pace(self, state, nbytes, bps):
        # Token bucket. Capacity is small (~100ms of traffic) so a stall
        # never earns a catch-up burst afterwards.
        now = time.monotonic()
        state["tokens"] = min(state["tokens"] + (now - state["last"]) * bps,
                              max(2.0 * nbytes, bps * 0.1))
        state["last"] = now
        if state["tokens"] < nbytes:
            need = (nbytes - state["tokens"]) / bps
            self.stop.wait(min(need, 0.5))
            now2 = time.monotonic()
            state["tokens"] += (now2 - state["last"]) * bps
            state["last"] = now2
        state["tokens"] -= nbytes

    def _run(self):
        # A sender thread must never die silently: without this, a bug in
        # the loop leaves the flow listed at 0 Mbps with the only evidence
        # buried in a thread traceback.
        try:
            if self.proto == "udp":
                self._run_udp()
            else:
                self._run_tcp()
        except Exception as exc:
            print("FLOW DIED %s -> %s: %r" % (self.me, self.dst, exc),
                  file=sys.stderr)
            sys.stderr.flush()
            raise

    def _open_tcp(self):
        # Manual socket instead of create_connection: TCP_MAXSEG must be
        # set before connect, and SO_SNDBUF before buffers are sized.
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(10)
        t = self.tuning
        try:
            if t["mss"]:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_MAXSEG, t["mss"])
            if t["sndbuf"]:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, t["sndbuf"])
            if t["nodelay"]:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        if t["bind_ip"]:
            sock.bind((t["bind_ip"], 0))
        sock.connect((self.addr, self.port))
        return sock

    def _run_tcp(self):
        backoff = RECONNECT_MIN
        chunk_cap = self.tuning["chunk"] or MAX_CHUNK
        payload = b"\x00" * max(chunk_cap, MAX_CHUNK)
        while not self.stop.is_set():
            sock = None
            try:
                sock = self._open_tcp()
                cur_mbps = self.mbps
                bps = cur_mbps * 125000.0
                self._apply_kernel_pacing(sock, bps)
                sock.sendall(MAGIC + b" " + self.me.encode() + b"\n")
                backoff = RECONNECT_MIN
                state = {"tokens": 0.0, "last": time.monotonic()}
                while not self.stop.is_set():
                    if self.mbps != cur_mbps:      # live reload changed the rate
                        cur_mbps = self.mbps
                        bps = cur_mbps * 125000.0
                        self._apply_kernel_pacing(sock, bps)
                    chunk = self._chunk_for(bps)
                    self._pace(state, chunk, bps)
                    if self.stop.is_set():
                        break
                    sock.sendall(payload[:chunk])
                    with self.lock:
                        self.bytes_sent += chunk
            except OSError:
                pass
            finally:
                if sock is not None:
                    try:
                        sock.close()
                    except OSError:
                        pass
            if not self.stop.is_set():
                with self.lock:
                    self.reconnects += 1
                self.stop.wait(backoff)
                backoff = min(backoff * 2, RECONNECT_MAX)

    def _udp_reply_reader(self, sock, pending):
        # Drains reply datagrams (request/response mode) off the sender's
        # connected socket: counts them and matches sampled seqs for RTT.
        while not self.stop.is_set():
            try:
                data = sock.recv(65535)
            except socket.timeout:
                continue
            except OSError:
                return
            if len(data) < len(RMAGIC) + 8 or not data.startswith(RMAGIC):
                continue
            rseq = struct.unpack("!Q", data[4:12])[0]
            t_now = time.monotonic()
            with self.lock:
                self.resp_pkts += 1
                self.resp_bytes += len(data)
                t_sent = pending.pop(rseq, None)
                if t_sent is not None:
                    self.rtt_sum += t_now - t_sent
                    self.rtt_n += 1

    def _run_udp(self):
        header = MAGIC + struct.pack("!B", len(self.me)) + self.me.encode()
        # Honor --udp-payload, but never below what the header needs.
        want = self.tuning["udp_payload"] or UDP_PAYLOAD
        pad = b"\x00" * max(0, want - len(header) - 8)
        seq = 0
        pending = {}   # sampled seq -> send time, shared with reply reader
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            if self.tuning["sndbuf"]:
                try:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF,
                                    self.tuning["sndbuf"])
                except OSError:
                    pass
            if self.tuning["bind_ip"]:
                sock.bind((self.tuning["bind_ip"], 0))
            sock.connect((self.addr, self.port))
            sock.settimeout(1)
            threading.Thread(target=self._udp_reply_reader, daemon=True,
                             args=(sock, pending)).start()
            state = {"tokens": 0.0, "last": time.monotonic()}
            cur_mbps = self.mbps
            bps = cur_mbps * 125000.0
            self._apply_kernel_pacing(sock, bps)
            size = len(header) + 8 + len(pad)
            while not self.stop.is_set():
                if self.mbps != cur_mbps:
                    cur_mbps = self.mbps
                    bps = cur_mbps * 125000.0
                self._pace(state, size, bps)
                if self.stop.is_set():
                    break
                try:
                    sock.send(header + struct.pack("!Q", seq) + pad)
                except OSError:
                    self.stop.wait(0.5)
                    continue
                with self.lock:
                    self.bytes_sent += size
                    self.pkts_sent += 1
                    # RTT sampling: every 64th request, bounded memory.
                    if seq % 64 == 0:
                        if len(pending) > 256:
                            pending.clear()
                        pending[seq] = time.monotonic()
                seq += 1
        finally:
            sock.close()


# ---------------------------------------------------------------------------
# Receiver
# ---------------------------------------------------------------------------

class RxBook(object):
    """Per-peer receive counters, shared between listener threads and
    the reporter."""

    def __init__(self):
        self.lock = threading.Lock()
        self.peers = {}   # name -> dict(bytes, pkts, max_seq)

    def account(self, name, nbytes, seq=None):
        with self.lock:
            p = self.peers.setdefault(name, {"bytes": 0, "pkts": 0, "max_seq": -1})
            p["bytes"] += nbytes
            p["pkts"] += 1
            if seq is not None and seq > p["max_seq"]:
                p["max_seq"] = seq

    def snapshot(self):
        with self.lock:
            return {k: dict(v) for k, v in self.peers.items()}


def _tcp_conn_reader(conn, peer_addr, book, stop):
    conn.settimeout(10)
    name = "?%s" % peer_addr[0]
    try:
        # Header line: "MXA1 <name>\n", capped so a stray client can't
        # make us buffer forever.
        buf = b""
        while b"\n" not in buf and len(buf) < 256:
            b = conn.recv(64)
            if not b:
                return
            buf += b
        line, _, rest = buf.partition(b"\n")
        if line.startswith(MAGIC + b" "):
            name = line[len(MAGIC) + 1:].decode(errors="replace").strip()
        if rest:
            book.account(name, len(rest))
        while not stop.is_set():
            try:
                data = conn.recv(MAX_CHUNK)
            except socket.timeout:
                continue
            if not data:
                return
            book.account(name, len(data))
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def tcp_listener(port, book, stop, rcvbuf=0, bind_ip=""):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if rcvbuf:
        # Set on the listener so accepted sockets inherit it.
        try:
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
        except OSError:
            pass
    srv.bind((bind_ip, port))
    srv.listen(1024)
    srv.settimeout(1)
    while not stop.is_set():
        try:
            conn, addr = srv.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        t = threading.Thread(target=_tcp_conn_reader, daemon=True,
                             args=(conn, addr, book, stop))
        t.start()
    srv.close()


def udp_listener(port, book, stop, rcvbuf=0, bind_ip="", respond=0):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF,
                        rcvbuf or 4 * 1024 * 1024)
    except OSError:
        pass
    sock.bind((bind_ip, port))
    sock.settimeout(1)
    hlen = len(MAGIC) + 1
    # Request/response mode: every request gets a reply of `respond`
    # bytes carrying the request's seq, straight back to the source.
    reply_pad = b"\x00" * max(0, respond - len(RMAGIC) - 8)
    while not stop.is_set():
        try:
            data, addr = sock.recvfrom(65535)
        except socket.timeout:
            continue
        except OSError:
            break
        if len(data) < hlen + 8 or not data.startswith(MAGIC):
            continue
        nlen = data[len(MAGIC)]
        if len(data) < hlen + nlen + 8:
            continue
        name = data[hlen:hlen + nlen].decode(errors="replace")
        seq_raw = data[hlen + nlen:hlen + nlen + 8]
        seq = struct.unpack("!Q", seq_raw)[0]
        book.account(name, len(data), seq)
        if respond:
            try:
                sock.sendto(RMAGIC + seq_raw + reply_pad, addr)
            except OSError:
                pass
    sock.close()


# ---------------------------------------------------------------------------
# Reporter
# ---------------------------------------------------------------------------

class Reporter(object):
    """Every interval, append per-flow tx/rx rows to the report CSV and
    print a one-line aggregate to stdout."""

    FIELDS = ["ts", "host", "dir", "peer", "proto",
              "target_mbps", "achieved_mbps", "bytes", "extra"]

    def __init__(self, me, path, interval, flows, book, rx_targets, proto,
                 respond=0):
        self.me, self.interval, self.proto = me, interval, proto
        self.respond = respond
        self.flows, self.book, self.rx_targets = flows, book, rx_targets
        self.prev_tx = {}
        self.prev_rx = {}
        self.last_tick = time.monotonic()
        new = not os.path.exists(path)
        self.fh = open(path, "a", newline="")
        self.csv = csv.writer(self.fh)
        if new:
            self.csv.writerow(self.FIELDS)

    def tick(self):
        now = int(time.time())
        # Rate over the *actual* elapsed time, not the nominal interval,
        # so the final partial tick and any scheduling drift stay honest.
        mono = time.monotonic()
        elapsed = max(mono - self.last_tick, 1e-3)
        self.last_tick = mono
        tx_sum = tx_target = 0.0
        for fl in self.flows:
            with fl.lock:
                total, rec = fl.bytes_sent, fl.reconnects
                pkts, rpk = fl.pkts_sent, fl.resp_pkts
                rtt_s, rtt_n = fl.rtt_sum, fl.rtt_n
            prev = self.prev_tx.get(fl.dst, (0, 0, 0, 0.0, 0))
            self.prev_tx[fl.dst] = (total, pkts, rpk, rtt_s, rtt_n)
            mbps = (total - prev[0]) * 8.0 / elapsed / 1e6
            tx_sum += mbps
            tx_target += fl.mbps
            if self.proto == "udp":
                dpkts = pkts - prev[1]
                extra = "pps=%d" % (dpkts / elapsed)
                drpk = rpk - prev[2]
                if drpk or self.respond:
                    extra += " resp_pct=%.1f" % (
                        min(100.0, drpk / dpkts * 100) if dpkts else 0.0)
                    drtt_n = rtt_n - prev[4]
                    if drtt_n:
                        extra += " rtt_ms=%.3f" % (
                            (rtt_s - prev[3]) / drtt_n * 1000)
            else:
                extra = "reconnects=%d" % rec
            self.csv.writerow([now, self.me, "tx", fl.dst, self.proto,
                               "%.3f" % fl.mbps, "%.3f" % mbps,
                               total - prev[0], extra])

        rx_sum = rx_target = 0.0
        snap = self.book.snapshot()
        for peer, cur in sorted(snap.items()):
            prev = self.prev_rx.get(peer, {"bytes": 0, "pkts": 0, "max_seq": -1})
            self.prev_rx[peer] = cur
            dbytes = cur["bytes"] - prev["bytes"]
            mbps = dbytes * 8.0 / elapsed / 1e6
            rx_sum += mbps
            target = self.rx_targets.get(peer, 0.0)
            rx_target += target
            extra = ""
            if self.proto == "udp" and cur["max_seq"] >= 0:
                dpkts = cur["pkts"] - prev["pkts"]
                extra = "pps=%d" % (dpkts / elapsed)
                dseq = cur["max_seq"] - prev["max_seq"]
                if dseq > 0:
                    extra += " loss_pct=%.2f" % (max(0.0, 1.0 - dpkts / dseq) * 100)
            self.csv.writerow([now, self.me, "rx", peer, self.proto,
                               "%.3f" % target, "%.3f" % mbps, dbytes, extra])
        self.fh.flush()
        print("ts=%d tx=%.1f/%.1fMbps rx=%.1f/%.1fMbps flows=%d peers=%d"
              % (now, tx_sum, tx_target, rx_sum, rx_target,
                 len(self.flows), len(snap)))
        sys.stdout.flush()


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

def cmd_run(args):
    try:
        threading.stack_size(512 * 1024)   # ~1000 threads at large N
    except (ValueError, RuntimeError):
        pass

    hosts, endpoints, rates = load_matrix(args.matrix, args.map)
    me = resolve_self(hosts, endpoints, args.hostname)
    port = endpoints[me][1]

    bind_ip = ""
    if args.bind:
        bind_iface, bind_ip = resolve_bind(args.bind)
        print("[bind] %s: %r -> iface=%s ip=%s" % (me, args.bind, bind_iface, bind_ip))

    stop = threading.Event()
    reload_flag = {"v": False}

    def on_stop(_sig, _frm):
        stop.set()

    signal.signal(signal.SIGTERM, on_stop)
    signal.signal(signal.SIGINT, on_stop)
    if hasattr(signal, "SIGHUP"):
        signal.signal(signal.SIGHUP, lambda s, f: reload_flag.update(v=True))

    tuning = {"chunk": args.chunk_bytes, "udp_payload": args.udp_payload,
              "sndbuf": args.sndbuf, "rcvbuf": args.rcvbuf,
              "mss": args.mss, "nodelay": args.nodelay, "bind_ip": bind_ip}

    book = RxBook()
    if not args.no_recv:
        threading.Thread(target=tcp_listener, daemon=True,
                         args=(port, book, stop, args.rcvbuf, bind_ip)).start()
        threading.Thread(target=udp_listener, daemon=True,
                         args=(port, book, stop, args.rcvbuf, bind_ip,
                               args.respond_bytes)).start()

    flows = []
    if not args.no_send:
        for (src, dst), mbps in sorted(rates.items()):
            if src != me:
                continue
            addr, dport = endpoints[dst]
            fl = Flow(me, dst, addr, dport, mbps, args.protocol, tuning)
            flows.append(fl)
            fl.start()

    rx_targets = {src: mbps for (src, dst), mbps in rates.items() if dst == me}

    os.makedirs(args.report_dir, exist_ok=True)
    report_path = os.path.join(args.report_dir, "%s_agent.csv" % me)
    rep = Reporter(me, report_path, args.interval, flows, book,
                   rx_targets, args.protocol, args.respond_bytes)

    print("matrix_agent: host=%s port=%d proto=%s tx_flows=%d expected_rx_peers=%d report=%s"
          % (me, port, args.protocol, len(flows), len(rx_targets), report_path))
    sys.stdout.flush()

    deadline = time.monotonic() + args.duration if args.duration > 0 else None
    next_tick = time.monotonic() + args.interval
    while not stop.is_set():
        stop.wait(max(0.0, min(next_tick - time.monotonic(), 0.5)))
        if reload_flag["v"]:
            reload_flag["v"] = False
            try:
                _h, _e, new_rates = load_matrix(args.matrix, args.map)
            except SystemExit as exc:
                print("reload failed: %s" % exc, file=sys.stderr)
            else:
                by_dst = {fl.dst: fl for fl in flows}
                for (src, dst), mbps in new_rates.items():
                    if src == me and dst in by_dst:
                        by_dst[dst].mbps = mbps
                rx_targets.clear()
                rx_targets.update({s: m for (s, d), m in new_rates.items() if d == me})
                print("reloaded rates from %s" % args.matrix)
        if time.monotonic() >= next_tick:
            rep.tick()
            next_tick += args.interval
        if deadline is not None and time.monotonic() >= deadline:
            stop.set()

    for fl in flows:
        fl.stop.set()
    # Flush a final partial interval so short runs still report, but only
    # if it's long enough to carry a meaningful rate.
    if time.monotonic() - rep.last_tick >= args.interval * 0.5:
        rep.tick()
    return 0


def cmd_gen(args):
    hosts = []
    with open(args.hosts) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                hosts.append(line)
    if len(hosts) < 2:
        raise SystemExit("need at least 2 hosts")
    n = len(hosts)
    if args.rate_mbps is not None:
        rate = args.rate_mbps
    else:
        rate = args.egress_gbps * 1000.0 / (n - 1)
    out = sys.stdout if args.output == "-" else open(args.output, "w", newline="")
    try:
        w = csv.writer(out)
        w.writerow(["src\\dst"] + hosts)
        for src in hosts:
            name_s, _, _ = parse_token(src)
            row = [src]
            for dst in hosts:
                name_d, _, _ = parse_token(dst)
                row.append("" if name_s == name_d else "%.3f" % rate)
            w.writerow(row)
    finally:
        if out is not sys.stdout:
            out.close()
    if args.output != "-":
        print("wrote %s: %d hosts, %.3f Mbps per pair, %.3f Gbps egress per host"
              % (args.output, n, rate, rate * (n - 1) / 1000.0))
    return 0


def cmd_check(args):
    hosts, _endpoints, rates = load_matrix(args.matrix, None)
    egress = {h: 0.0 for h in hosts}
    ingress = {h: 0.0 for h in hosts}
    for (s, d), m in rates.items():
        egress[s] += m
        ingress[d] += m

    def report(kind, sums, cap_gbps):
        worst = sorted(sums.items(), key=lambda kv: -kv[1])
        top = ", ".join("%s=%.0fMbps" % kv for kv in worst[:3])
        print("%s: max %.1f Mbps (%s)" % (kind, worst[0][1], top))
        bad = []
        if cap_gbps is not None:
            cap = cap_gbps * 1000.0
            bad = [(h, v) for h, v in worst if v > cap]
            for h, v in bad:
                print("  VIOLATION %s %s %.1f Mbps > cap %.1f Mbps"
                      % (kind, h, v, cap))
        return bad

    bad = report("egress", egress, args.egress_gbps)
    bad += report("ingress", ingress, args.ingress_gbps)
    total = sum(rates.values())
    print("total offered load: %.2f Gbps across %d flows, %d hosts"
          % (total / 1000.0, len(rates), len(hosts)))
    if bad:
        print("matrix is NOT admissible (%d violations)" % len(bad))
        return 1
    print("matrix is admissible against the given caps"
          if (args.egress_gbps or args.ingress_gbps) else
          "no caps given (--egress-gbps/--ingress-gbps) -- sums only")
    return 0


def cmd_hosts(args):
    # Machine-readable host list for fleet tooling (fleet.sh): one line
    # per host, "name addr port", in matrix order.
    hosts, endpoints, _rates = load_matrix(args.matrix, None)
    for name in hosts:
        addr, port = endpoints[name]
        print("%s %s %d" % (name, addr, port))
    return 0


def _write_grid_outputs(gdir, agg, protos, latest, window):
    """Materialize the window aggregate as files the sweep tooling reads.

    - achieved_grid.csv / deficit_grid.csv: N x N grids in the traffic
      matrix's shape (rows sources, columns destinations, Mbit/s).
    - iperf_results.csv: the orchestrator's parse-csv column layout, one
      row per flow, so make-pivot and make-heatmap render matrix runs
      exactly like a sweep. All rows share one timestamp and carry the
      window as duration, which makes the pivot/heatmap time-averaging
      come out to the plain window average.
    """
    os.makedirs(gdir, exist_ok=True)
    hosts = sorted({h for (h, _p) in agg} | {p for (_h, p) in agg})
    ach, tgt = {}, {}
    for (host, peer), a in agg.items():           # rx rows: peer -> host
        tgt[(peer, host)] = a[0] / a[2]
        ach[(peer, host)] = a[1] / a[2]
    deficit = {k: max(0.0, tgt[k] - v) for k, v in ach.items()}
    for name, cells in (("achieved_grid.csv", ach), ("deficit_grid.csv", deficit)):
        with open(os.path.join(gdir, name), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["src\\dst"] + hosts)
            for s in hosts:
                w.writerow([s] + ["%.3f" % cells[(s, d)] if (s, d) in cells else ""
                                  for d in hosts])
    cols = ["timestamp", "source", "target", "status", "protocol", "duration_s",
            "parallel_streams", "bind_iface", "bind_ip",
            "bytes_transferred", "bps", "mbps",
            "src_port", "dst_port", "pair_a", "pair_b", "filename", "error"]
    stamp = time.strftime("%Y%m%d%H%M%S", time.localtime(latest))
    results = os.path.join(gdir, "iperf_results.csv")
    with open(results, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for (src, dst), mbps in sorted(ach.items()):
            byts = int(mbps * 1e6 / 8 * window)
            w.writerow({"timestamp": stamp, "source": src, "target": dst,
                        "status": "OK", "protocol": protos.get((src, dst), "tcp").upper(),
                        "duration_s": window, "parallel_streams": 1,
                        "bind_iface": "", "bind_ip": "",
                        "bytes_transferred": byts, "bps": int(mbps * 1e6),
                        "mbps": "%.3f" % mbps,
                        "src_port": "", "dst_port": "", "pair_a": src, "pair_b": dst,
                        "filename": "matrix_agent", "error": ""})
    base = os.path.basename(os.path.abspath(gdir))
    parent = os.path.dirname(os.path.abspath(gdir)) or "."
    print("wrote %s/{achieved_grid.csv,deficit_grid.csv,iperf_results.csv}" % gdir)
    print("render the sweep-style views with:")
    print("  iperf-orchestrator -o '%s' --run-id '%s' make-pivot" % (parent, base))
    print("  iperf-orchestrator -o '%s' --run-id '%s' make-heatmap" % (parent, base))


def cmd_summarize(args):
    rows = []
    for path in args.reports:
        with open(path, newline="") as f:
            for r in csv.DictReader(f):
                rows.append(r)
    if not rows:
        raise SystemExit("no report rows found")
    latest = max(int(r["ts"]) for r in rows)
    cutoff = latest - args.window
    recent = [r for r in rows if int(r["ts"]) >= cutoff and r["dir"] == "rx"]
    agg = {}     # (host, peer) -> [sum_target, sum_achieved, n]
    protos = {}  # (src, dst) -> proto
    for r in recent:
        key = (r["host"], r["peer"])
        a = agg.setdefault(key, [0.0, 0.0, 0])
        a[0] += float(r["target_mbps"])
        a[1] += float(r["achieved_mbps"])
        a[2] += 1
        protos[(r["peer"], r["host"])] = r.get("proto", "tcp")
    tt = sum(a[0] / a[2] for a in agg.values())
    ta = sum(a[1] / a[2] for a in agg.values())
    print("window: last %ds (%d samples, %d flows)"
          % (args.window, len(recent), len(agg)))
    print("aggregate rx: %.1f / %.1f Mbps (%.1f%% of target)"
          % (ta, tt, (ta / tt * 100) if tt else 0.0))
    # Per-host totals, receiver-side truth for both directions: a host's
    # "in" sums its own rx rows, its "out" sums every peer's rx rows for
    # flows it sent. Worst-first separates one sick host from congested
    # fabric at a glance.
    per_host = {}   # h -> [in_target, in_achieved, out_target, out_achieved]
    for (host, peer), a in agg.items():
        t, ach = a[0] / a[2], a[1] / a[2]
        hs = per_host.setdefault(host, [0.0, 0.0, 0.0, 0.0])
        hs[0] += t
        hs[1] += ach
        ps = per_host.setdefault(peer, [0.0, 0.0, 0.0, 0.0])
        ps[2] += t
        ps[3] += ach

    def _frac(ach, t):
        return ach / t if t else 1.0

    ranked = sorted(per_host.items(),
                    key=lambda kv: min(_frac(kv[1][1], kv[1][0]),
                                       _frac(kv[1][3], kv[1][2])))
    print("per host (rx in / tx out, achieved/target Mbps, worst first):")
    for h, (it, ia, ot, oa) in ranked[:args.top_hosts]:
        print("  %-24s in %8.1f/%-8.1f (%3.0f%%)   out %8.1f/%-8.1f (%3.0f%%)"
              % (h, ia, it, _frac(ia, it) * 100, oa, ot, _frac(oa, ot) * 100))
    if len(ranked) > args.top_hosts:
        print("  ... %d more hosts (raise --top-hosts)"
              % (len(ranked) - args.top_hosts))
    deficits = []
    for (host, peer), a in agg.items():
        t, ach = a[0] / a[2], a[1] / a[2]
        if t > 0:
            deficits.append((ach / t, host, peer, t, ach))
    deficits.sort()
    if deficits:
        print("worst flows (achieved/target):")
        for frac, host, peer, t, ach in deficits[:args.top]:
            print("  %s -> %s: %.1f / %.1f Mbps (%.0f%%)"
                  % (peer, host, ach, t, frac * 100))
    if args.grid:
        if not agg:
            raise SystemExit("--grid: no rx rows inside the window")
        _write_grid_outputs(args.grid, agg, protos, latest, args.window)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="matrix_agent", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")

    g = sub.add_parser("gen", help="generate a uniform matrix from a host list")
    g.add_argument("--hosts", required=True, help="file with one host token per line")
    rate = g.add_mutually_exclusive_group(required=True)
    rate.add_argument("--rate-mbps", type=float, help="Mbps for every pair")
    rate.add_argument("--egress-gbps", type=float,
                      help="per-host total egress, split evenly across peers")
    g.add_argument("--output", "-o", default="-", help="output file (default stdout)")

    c = sub.add_parser("check", help="admissibility check")
    c.add_argument("--matrix", required=True)
    c.add_argument("--egress-gbps", type=float, help="per-host NIC egress cap")
    c.add_argument("--ingress-gbps", type=float, help="per-host NIC ingress cap")

    r = sub.add_parser("run", help="run the agent")
    r.add_argument("--matrix", required=True)
    r.add_argument("--hostname", help="this host's name in the matrix (default: gethostname)")
    r.add_argument("--protocol", choices=["tcp", "udp"], default="tcp")
    r.add_argument("--interval", type=float, default=10.0, help="report interval seconds")
    r.add_argument("--report-dir", default="reports")
    r.add_argument("--duration", type=float, default=0.0,
                   help="exit after N seconds (0 = run until signalled)")
    r.add_argument("--no-send", action="store_true", help="receiver only")
    r.add_argument("--no-recv", action="store_true", help="sender only")
    r.add_argument("--map", action="append", default=[], metavar="NAME=ADDR[:PORT]",
                   help="override a host's address (repeatable; for testing)")
    r.add_argument("--respond-bytes", type=int, default=0, metavar="BYTES",
                   help="request/response mode (UDP): reply to every received "
                        "request datagram with a BYTES-sized response; the "
                        "requester side then reports resp_pct and sampled "
                        "rtt_ms per flow (default: no replies)")
    r.add_argument("--udp-payload", type=int, default=UDP_PAYLOAD, metavar="BYTES",
                   help="UDP datagram size (default %d; >MTU exercises fragmentation)" % UDP_PAYLOAD)
    r.add_argument("--chunk-bytes", type=int, default=0, metavar="BYTES",
                   help="fixed TCP write size (default: auto ~10 writes/sec)")
    r.add_argument("--sndbuf", type=int, default=0, metavar="BYTES",
                   help="SO_SNDBUF per flow (default: kernel autotuning)")
    r.add_argument("--rcvbuf", type=int, default=0, metavar="BYTES",
                   help="SO_RCVBUF on listeners (default: kernel autotuning; UDP 4MB)")
    r.add_argument("--mss", type=int, default=0, metavar="BYTES",
                   help="TCP_MAXSEG: cap TCP segment size (approximates packet-size control)")
    r.add_argument("--bind", default=os.environ.get("IPERF_BIND", ""), metavar="SPEC",
                   help="pin traffic to a NIC, iperf-orchestrator style: substring "
                        "matched against `ip -o -4 addr show` (iface name or address); "
                        "binds sender source addresses and both listeners "
                        "(default: $IPERF_BIND, same env var as the orchestrator)")
    r.add_argument("--nodelay", action="store_true",
                   help="set TCP_NODELAY (with --chunk-bytes, emulates small-message senders)")

    hl = sub.add_parser("hosts", help="list matrix hosts (name addr port)")
    hl.add_argument("--matrix", required=True)

    s = sub.add_parser("summarize", help="aggregate report CSVs")
    s.add_argument("reports", nargs="+", help="report CSV files")
    s.add_argument("--window", type=int, default=30, help="seconds of history to use")
    s.add_argument("--top", type=int, default=10, help="worst flows to list")
    s.add_argument("--top-hosts", type=int, default=10,
                   help="hosts to list in the per-host table (worst first)")
    s.add_argument("--grid", metavar="DIR",
                   help="also write achieved/deficit N x N grid CSVs and an "
                        "orchestrator-compatible iperf_results.csv into DIR, "
                        "so make-pivot/make-heatmap render matrix runs")

    args = ap.parse_args(argv)
    if args.cmd is None:
        ap.print_help()
        return 2
    return {"gen": cmd_gen, "check": cmd_check, "run": cmd_run,
            "hosts": cmd_hosts, "summarize": cmd_summarize}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
