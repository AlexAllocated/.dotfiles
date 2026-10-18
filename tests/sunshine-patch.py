#!/usr/bin/env python3
"""Compile and exercise actual patched Sunshine functions during its Nix build.

Only dependencies (DRM inventory, HTTP response, process/display operations and
timers) are stubbed. Function bodies come from the build's patched source, so a
misplaced hunk, unsafe fallback or missing failure cleanup fails this check.
This is not a hardware, encoder, or two-client streaming acceptance test.
"""
from pathlib import Path
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


def block(source, signature):
    """Extract one brace-balanced C++ definition, ignoring comments/literals."""
    if source.count(signature) != 1:
        raise ValueError(f"expected exactly one definition: {signature}")
    start = source.index(signature)
    opening = source.index("{", start + len(signature))
    tokens = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]')
    depth = 0
    for match in tokens.finditer(source, opening):
        if match[0] == "{":
            depth += 1
        elif match[0] == "}":
            depth -= 1
            if depth == 0:
                return source[start:match.end()]
    raise ValueError(f"unclosed definition: {signature}")


PREFIX = r'''
#include <algorithm>
#include <cassert>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <format>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <ranges>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>
using namespace std::literals;
std::ostringstream test_log;
#define BOOST_LOG(level) test_log
namespace util {
int from_view(std::string_view s) { return s.empty() ? 0 : std::stoi(std::string(s)); }
template<class F> struct fail_guard {
  F fn;
  explicit fail_guard(F f): fn(f) {}
  ~fail_guard() { fn(); }
};
}
const char* drmModeGetConnectorTypeName(unsigned type) { return type == 1 ? "DP" : "HDMI-A"; }
namespace config {
struct { std::string output_name; struct { bool config_revert_on_disconnect = false; } dd; } video;
struct { int ping_timeout = 5; } stream;
constexpr int ENCRYPTION_MODE_MANDATORY = 1;
}
'''

CONNECTORS = r'''
struct monitor_descriptor_t { unsigned type, index; int monitor_index; };
struct card_descriptor_t { std::map<unsigned, monitor_descriptor_t> crtc_to_monitor; };
std::vector<card_descriptor_t> card_descriptors;
'''

CONNECTOR_TESTS = r'''
void check_connectors() {
  // Disconnected connectors are present in upstream's inventory, with a
  // value-initialized monitor_index of zero. They must never select DP-1.
  kms::card_descriptors = {{{{10, {1, 1, 0}}, {20, {1, 2, 1}}, {0, {1, 3, 0}}}}};
  std::vector<kms::connector_t> connectors = {
    {1, 0, 3, 103, false}, {1, 20, 2, 102, true}, {1, 10, 1, 101, true}
  };
  assert(kms::map_display_name_to_monitor_index("DP-2") == 1);
  assert(kms::map_display_name_to_monitor_index("unknown") == -1);
  assert(kms::map_display_name_to_monitor_index("DP-3") == 0);
  assert(kms::monitor_matches_display("DP-2", 1, 1, connectors, 20));
  assert(!kms::monitor_matches_display("DP-2", 1, 0, connectors, 10));
  assert(!kms::monitor_matches_display("DP-3", 0, 0, connectors, 10));
  assert(!kms::monitor_matches_display("DP-3", 0, 0, connectors, 0));
  assert(!kms::monitor_matches_display("unknown", -1, 0, connectors, 10));
  assert(!kms::monitor_matches_display("DP", -1, 0, connectors, 10));
  assert(!kms::monitor_matches_display("dp-1", -1, 0, connectors, 10));
  assert(kms::map_display_name_to_monitor_index("") == 0);
  assert(kms::monitor_matches_display("", 0, 0, connectors, 10));
  assert(!kms::monitor_matches_display("", 0, 1, connectors, 20));
  assert(kms::monitor_matches_display("0", 0, 0, connectors, 10));
  assert(kms::monitor_matches_display("1", 1, 1, connectors, 20));
  assert(!kms::monitor_matches_display("1", 1, 0, connectors, 10));
  assert(enumerated_name(true) == "DP-2");
  assert(enumerated_name(false) == "7");
}
void check_environment(const char* start, const char* stop, const char* directory) {
  auto dir = std::filesystem::path(directory);
  const auto selected = dir / "selected";
  unsetenv("SUNSHINE_STREAM_START_COMMAND");
  unsetenv("SUNSHINE_SELECTED_OUTPUT_FILE");
  unsetenv("SUNSHINE_STREAM_STOP_COMMAND");
  config::video.output_name = "original";
  assert(hooks::streaming_will_prepare(2560, 1440, 60));
  hooks::streaming_will_stop();
  assert(!std::filesystem::exists(dir / "started"));
  assert(!std::filesystem::exists(dir / "stopped"));
  setenv("SUNSHINE_STREAM_START_COMMAND", "", 1);
  setenv("SUNSHINE_STREAM_STOP_COMMAND", "", 1);
  assert(hooks::streaming_will_prepare(2560, 1440, 60));
  hooks::streaming_will_stop();
  assert(!std::filesystem::exists(dir / "stopped"));
  setenv("SUNSHINE_STREAM_START_COMMAND", start, 1);
  assert(hooks::streaming_will_prepare(2560, 1440, 60));
  std::string args;
  std::ifstream(dir / "started") >> args;
  assert(args == "2560,1440,60");
  assert(config::video.output_name == "original");
  setenv("SUNSHINE_SELECTED_OUTPUT_FILE", selected.c_str(), 1);
  // Missing, empty and unsafe output must not overwrite the previous choice.
  assert(!hooks::streaming_will_prepare(2560, 1440, 60));
  for (const auto value : {"", "DP 1", "../DP-1", "DP-1;touch_x", "DP-1\r"}) {
    std::ofstream(selected) << value;
    assert(!hooks::streaming_will_prepare(2560, 1440, 60));
    assert(config::video.output_name == "original");
  }
  std::ofstream(selected) << "DP-2\n";
  assert(hooks::streaming_will_prepare(2560, 1440, 60));
  assert(config::video.output_name == "DP-2");
  setenv("SUNSHINE_STREAM_START_COMMAND", "false", 1);
  std::ofstream(selected) << "HDMI-A-1\n";
  assert(!hooks::streaming_will_prepare(2560, 1440, 60));
  assert(config::video.output_name == "DP-2");
  setenv("SUNSHINE_STREAM_STOP_COMMAND", stop, 1);
  hooks::streaming_will_stop();
  assert(std::filesystem::exists(dir / "stopped"));
}
'''

SESSION_STUBS = r'''
std::vector<std::string> events;
int active_sessions = 0, current_app = 0, execute_error = 0, encryption_mode = 0;
bool prepare_ok = true, probe_error = false, cipher = true;
int last_status = 0;
struct launch_session_t {
  int width = 2560, height = 1440, fps = 60, unique_id = 123;
  bool rtsp_cipher = cipher;
  std::string rtsp_url_scheme = "rtsp://";
};
namespace pt {
struct ptree {
  std::map<std::string, std::string> data;
  bool empty() const { return data.empty(); }
  template<class T> void put(std::string key, T value) {
    std::ostringstream output; output << value; data[key] = output.str();
  }
};
void write_xml(std::ostream &out, const ptree &tree) {
  out << tree.data.at("root.<xmlattr>.status_code");
}
}
struct Response {
  bool close_connection_after_response = false;
  void write(const std::string &s) { last_status = std::stoi(s); }
};
struct Endpoint { int address() { return 0; } };
using args_t = std::map<std::string, std::string>;
struct Request {
  args_t args {{"rikey", "x"}, {"rikeyid", "1"}, {"localAudioPlayMode", "1"}, {"appid", "1"}};
  args_t parse_query_string() { return args; }
  Endpoint remote_endpoint() { return {}; }
  Endpoint local_endpoint() { return {}; }
};
using resp_https_t = std::shared_ptr<Response>;
using req_https_t = std::shared_ptr<Request>;
struct SunshineHTTPS {};
template<class T> void print_req(req_https_t) {}
constexpr auto EMPTY_PROPERTY_TREE_ERROR_MSG = "empty response";
std::string get_arg(const args_t &args, const std::string &key) { return args.at(key); }
std::shared_ptr<launch_session_t> make_launch_session(bool, const args_t &) {
  return std::make_shared<launch_session_t>();
}
namespace proc {
struct Process {
  int running() { return current_app; }
  int execute(int, std::shared_ptr<launch_session_t>) { events.push_back("execute"); return execute_error; }
} proc;
}
namespace display_device {
template<class T> void configure_display(T &, const launch_session_t &) { events.push_back("configure"); }
void revert_configuration() { events.push_back("revert"); }
}
namespace video { bool probe_encoders() { events.push_back("probe"); return probe_error; } }
namespace platf {
bool streaming_will_prepare(int width, int height, int fps) {
  assert(width == 2560 && height == 1440 && fps == 60);
  events.push_back("prepare"); return prepare_ok;
}
void streaming_will_stop() { events.push_back("stop"); }
}
namespace net {
int encryption_mode_for_address(int) { return encryption_mode; }
std::string addr_to_url_escaped_string(int) { return "localhost"; }
int map_port(int p) { return p; }
}
namespace rtsp_stream {
constexpr int RTSP_SETUP_PORT = 48010;
int session_count() { return active_sessions; }
void launch_session_raise(std::shared_ptr<launch_session_t>) { events.push_back("raise"); }
}
namespace boost::system { using error_code = bool; }
struct LaunchEvent {
  std::shared_ptr<launch_session_t> pending;
  auto view(std::chrono::seconds) { return pending; }
  void raise(std::shared_ptr<launch_session_t> next) { pending = next; }
  auto pop(std::chrono::seconds) { return std::exchange(pending, {}); }
};
struct Timer {
  std::function<void(bool)> callback;
  void expires_after(int) {}
  template<class F> void async_wait(F fn) { callback = fn; }
};
namespace input { void terminate_gamepads() { events.push_back("gamepads"); } }
'''

SESSION_TESTS = r'''
void reset() {
  events.clear(); active_sessions = current_app = execute_error = encryption_mode = last_status = 0;
  prepare_ok = cipher = true; probe_error = false;
}
void check_sessions() {
  bool host_audio = false;
  auto request = std::make_shared<Request>();
  auto response = std::make_shared<Response>();
  reset(); launch(host_audio, response, request);
  assert(last_status == 200);
  assert((events == std::vector<std::string>{"configure", "prepare", "probe", "execute", "raise"}));
  reset(); prepare_ok = false; launch(host_audio, response, request);
  assert(last_status == 503);
  assert((events == std::vector<std::string>{"configure", "prepare", "revert", "stop"}));
  reset(); probe_error = true; launch(host_audio, response, request);
  assert(last_status == 503);
  assert((events == std::vector<std::string>{"configure", "prepare", "probe", "revert", "stop"}));
  reset(); cipher = false; encryption_mode = 1; launch(host_audio, response, request);
  assert(last_status == 403);
  assert((events == std::vector<std::string>{"configure", "prepare", "probe", "revert", "stop"}));
  reset(); execute_error = 500; launch(host_audio, response, request);
  assert(last_status == 500);
  assert((events == std::vector<std::string>{"configure", "prepare", "probe", "execute", "revert", "stop"}));
  reset(); current_app = 1; resume(host_audio, response, request);
  assert(last_status == 200);
  assert((events == std::vector<std::string>{"configure", "prepare", "probe", "raise"}));
  reset(); current_app = 1; prepare_ok = false; resume(host_audio, response, request);
  assert(last_status == 503);
  assert((events == std::vector<std::string>{"configure", "prepare", "stop"}));
  reset(); current_app = 1; probe_error = true; resume(host_audio, response, request);
  assert(last_status == 503);
  assert((events == std::vector<std::string>{"configure", "prepare", "probe", "stop"}));
  reset(); current_app = 1; cipher = false; encryption_mode = 1; resume(host_audio, response, request);
  assert(last_status == 403);
  assert((events == std::vector<std::string>{"configure", "prepare", "probe", "stop"}));
  reset(); current_app = active_sessions = 1; resume(host_audio, response, request);
  assert(last_status == 200 && events == std::vector<std::string>{"raise"});
  reset(); current_app = active_sessions = 1; cipher = false; encryption_mode = 1;
  resume(host_audio, response, request);
  assert(last_status == 403 && events.empty());
  reset(); request->args.clear(); launch(host_audio, response, request);
  assert(last_status == 400 && events.empty());
  current_app = 1; resume(host_audio, response, request);
  assert(last_status == 400 && events.empty());
  reset(); resume(host_audio, response, request);
  assert(last_status == 503 && events.empty());

  reset(); Server server;
  auto session = std::make_shared<launch_session_t>();
  server.session_raise(session); server.raised_timer.callback(false);
  assert(events == std::vector<std::string>{"stop"});
  reset(); active_sessions = 1;
  server.session_raise(session); server.raised_timer.callback(false);
  assert(events.empty());
  reset(); server.session_raise(session); server.raised_timer.callback(true);
  assert(events.empty() && server.launch_event.pending == session);
  auto replacement = std::make_shared<launch_session_t>();
  server.session_raise(replacement);
  assert(server.launch_event.pending == session);
  server.launch_event.pending.reset(); server.raised_timer.callback(false);
  assert(events.empty());

  reset(); current_app = 1; int running_sessions = 2;
  disconnect(running_sessions);
  assert(running_sessions == 1 && events.empty());
  disconnect(running_sessions);
  assert(running_sessions == 0 && events == std::vector<std::string>{"stop"});
}
'''


def harness(root):
    kms = (root / "src/platform/linux/kmsgrab.cpp").read_text()
    misc = (root / "src/platform/linux/misc.cpp").read_text()
    http = (root / "src/nvhttp.cpp").read_text()
    rtsp = (root / "src/rtsp.cpp").read_text()
    stream = (root / "src/stream.cpp").read_text()
    # Also bind the tested selector to the capture path. The function tests
    # alone cannot detect a future upstream edit that bypasses the helper.
    display = block(kms, "class display_t:")
    init = block(display, "int init(const std::string &display_name, const ::video::config_t &config)")
    selection = block(init, "if (!monitor_matches_display(")
    if "continue;" not in selection or init.index(selection) > init.index("auto fb = card.fb(plane.get());"):
        raise ValueError("connector selection must reject the plane before framebuffer capture")
    # Extract the actual guarded name emission, not a reproduction of it.
    enumeration = re.search(r'if \(it != std::end\(crtc_to_monitor\)\) \{\s*display_names\.emplace_back[\s\S]*?\n        count\+\+;', kms)
    if not enumeration:
        raise ValueError("missing guarded connector-name enumeration")
    return "\n".join([
        PREFIX, "namespace kms {", block(kms, "struct connector_t ") + ";", CONNECTORS,
        block(kms, "static int64_t map_display_name_to_monitor_index("),
        block(kms, "static bool monitor_matches_display("), "}",
        "std::string enumerated_name(bool known) {\n"
        "std::map<unsigned, kms::monitor_descriptor_t> crtc_to_monitor {{20, {1, 2, 1}}};\n"
        "auto it = crtc_to_monitor.find(known ? 20 : 99); int count = 7;\n"
        "std::vector<std::string> display_names;\n" + enumeration[0] + "\nreturn display_names.at(0); }",
        "namespace hooks {", block(misc, "bool streaming_will_prepare("),
        block(misc, "void streaming_will_stop("), "}", CONNECTOR_TESTS, SESSION_STUBS,
        block(http, "void launch(bool &host_audio,"), block(http, "void resume(bool &host_audio,"),
        "struct Server { LaunchEvent launch_event; Timer raised_timer;\n"
        "int session_count() { return active_sessions; }\n" +
        block(rtsp, "void session_raise(std::shared_ptr<launch_session_t>") + "\n};",
        "void disconnect(int &running_sessions) {\n" +
        block(stream, "if (--running_sessions == 0)") + "\n}", SESSION_TESTS,
        "int main(int argc, char **argv) { assert(argc == 4); check_connectors(); "
        "check_environment(argv[1], argv[2], argv[3]); check_sessions(); "
        'std::cout << "Sunshine patched-source behavior checks passed\\n"; }',
    ])


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: sunshine-patch.py <patched-sunshine-source>")
    source = Path(sys.argv[1])
    with tempfile.TemporaryDirectory(prefix="sunshine-patch-test-") as temporary:
        work = Path(temporary)
        cpp = work / "check.cpp"
        cpp.write_text(harness(source))
        compiler = shlex.split(os.environ.get("CXX", "c++"))
        subprocess.run([*compiler, "-std=c++23", "-O0", "-Wall", "-Wextra", str(cpp), "-o", str(work / "check")], check=True)
        shell = shutil.which("bash")
        if shell is None:
            raise SystemExit("bash is required for local helper fixtures")
        start, stop = work / "start.sh", work / "stop.sh"
        start.write_text('printf "%s,%s,%s\\n" "$1" "$2" "$3" > ' + shlex.quote(str(work / "started")) + "\n")
        stop.write_text("touch " + shlex.quote(str(work / "stopped")) + "\n")
        subprocess.run([str(work / "check"), shlex.join([shell, str(start)]), shlex.join([shell, str(stop)]), str(work)], check=True)


if __name__ == "__main__":
    main()
