// Drive the synthesized RGB10 AXI4-Stream top from the VHDL decoder's top-down BMP.
#include "Vsurface_contour_select.h"
#include "verilated.h"

#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

using Bytes = std::vector<std::uint8_t>;
static std::uint32_t le32(const Bytes& bytes, std::size_t offset) {
    return std::uint32_t(bytes.at(offset)) | (std::uint32_t(bytes.at(offset + 1)) << 8)
         | (std::uint32_t(bytes.at(offset + 2)) << 16) | (std::uint32_t(bytes.at(offset + 3)) << 24);
}
static void tick(Vsurface_contour_select& dut) {
    dut.aclk = 1;
    dut.eval();
    dut.aclk = 0;
    dut.eval();
}
static std::uint32_t random_word(std::uint32_t& state) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}
static int simulate(int argc, char** argv) {
    const bool stalls = argc == 4 && std::string(argv[3]) == "--stalls";
    if (argc != 3 && !stalls) throw std::runtime_error("Usage: netlist_frame decoded.bmp output.bmp [--stalls]");
    std::ifstream file(argv[1], std::ios::binary);
    if (!file) throw std::runtime_error("Cannot open decoded BMP");
    Bytes input((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    if (input.size() < 54 || input[0] != 'B' || input[1] != 'M' || le32(input, 14) != 40 ||
        le32(input, 26) != 0x00180001u || le32(input, 30) != 0)
        throw std::runtime_error("Expected an uncompressed RGB24 BMP");
    const unsigned width = le32(input, 18);
    const int signed_height = static_cast<std::int32_t>(le32(input, 22));
    if (width == 0 || width > 65535 || signed_height >= 0 || signed_height < -65535)
        throw std::runtime_error("Expected a top-down BMP with 16-bit video dimensions");
    const unsigned height = static_cast<unsigned>(-signed_height);
    const unsigned offset = le32(input, 10), stride = (3 * width + 3) & ~3u;
    if (offset < 54 || input.size() != offset + std::size_t(stride) * height)
        throw std::runtime_error("Invalid BMP pitch or payload");
    Bytes output = input;
    const std::uint64_t total = std::uint64_t(width) * height;
    auto pixel_offset = [=](std::uint64_t pixel) {
        return offset + (pixel / width) * stride + 3 * (pixel % width);
    };

    Vsurface_contour_select dut;
    dut.aclk = 0;
    dut.aresetn = 0;
    dut.enable = 0;
    dut.dimensions = (height << 16) | width;
    dut.s_axis_tvalid = 0;
    dut.s_axis_tdata = 0;
    dut.s_axis_tuser = 0;
    dut.s_axis_tlast = 0;
    dut.m_axis_tready = 0;
    dut.eval();
    for (int n = 0; n < 5; ++n) tick(dut);
    dut.aresetn = 1;
    dut.enable = 1;

    std::uint64_t sent = 0, received = 0, cycles = 0, blocked = 0;
    unsigned lines = 0, starts = 0;
    bool presenting = false, held = false;
    unsigned held_data = 0, held_sof = 0, held_eol = 0;
    std::uint32_t rng = 0xb428316du;
    const std::uint64_t timeout = 12ull * (width + 100) * (height + 100);
    while (received < total && cycles < timeout) {
        const unsigned random = random_word(rng);
        if (!presenting && sent < total) presenting = !stalls || (random & 7) != 0;
        dut.s_axis_tvalid = presenting;
        dut.s_axis_tuser = presenting && sent == 0;
        dut.s_axis_tlast = presenting && sent % width == width - 1;
        if (presenting) {
            const std::size_t i = pixel_offset(sent);
            dut.s_axis_tdata = (std::uint32_t(input[i+2]) << 22) | (std::uint32_t(input[i+1]) << 12)
                             | (std::uint32_t(input[i]) << 2) | 0x00100803u;
        }
        dut.m_axis_tready = !stalls || ((random >> 8) & 3) != 0;
        dut.eval();
        if (held && (!dut.m_axis_tvalid || dut.m_axis_tdata != held_data ||
            dut.m_axis_tuser != held_sof || dut.m_axis_tlast != held_eol))
            throw std::runtime_error("Master output changed under backpressure");
        held = dut.m_axis_tvalid && !dut.m_axis_tready;
        if (held) {
            held_data = dut.m_axis_tdata;
            held_sof = dut.m_axis_tuser;
            held_eol = dut.m_axis_tlast;
            ++blocked;
        }
        if (dut.s_axis_tvalid && dut.s_axis_tready) {
            ++sent;
            presenting = false;
        }
        if (dut.m_axis_tvalid && dut.m_axis_tready) {
            const std::uint32_t data = dut.m_axis_tdata;
            if (!dut.filtered || bool(dut.m_axis_tuser) != (received == 0) ||
                bool(dut.m_axis_tlast) != (received % width == width-1) || (data & 0xc0300c03u))
                throw std::runtime_error("Invalid framing or RGB10 lane padding");
            const std::size_t i = pixel_offset(received);
            output[i] = (data >> 2) & 255;
            output[i+1] = (data >> 12) & 255;
            output[i+2] = (data >> 22) & 255;
            starts += dut.m_axis_tuser;
            lines += dut.m_axis_tlast;
            ++received;
        }
        tick(dut);
        ++cycles;
    }
    if (received != total || sent != total || starts != 1 || lines != height || (stalls && blocked == 0))
        throw std::runtime_error("Incorrect transfer or stall count");
    dut.s_axis_tvalid = 0;
    dut.m_axis_tready = 1;
    for (int n = 0; n < 50; ++n) {
        dut.eval();
        if (dut.m_axis_tvalid) throw std::runtime_error("Extra output transfer after frame");
        tick(dut);
    }
    std::ofstream image(argv[2], std::ios::binary);
    image.write(reinterpret_cast<const char*>(output.data()), output.size());
    image.close();
    if (!image) throw std::runtime_error("Could not write BMP");
    std::cout << "PASS " << width << " x " << height << ", " << received << " pixels, " << starts
              << " SOF, " << lines << " EOL, " << blocked << " stalled output clocks, "
              << cycles << " clocks through the last transfer\n";
    dut.final();
    return 0;
}
int main(int argc, char** argv) {
    try { return simulate(argc, argv); }
    catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
