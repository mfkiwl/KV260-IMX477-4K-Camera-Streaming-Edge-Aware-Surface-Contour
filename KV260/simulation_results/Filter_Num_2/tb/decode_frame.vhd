use work.jpeg_reader_pkg.all;
use work.bmp_writer_pkg.all;
entity decode_frame is generic (G_INPUT : string; G_OUTPUT : string); end;
architecture bench of decode_frame is begin
  process
    variable pixels : frame_ptr;
    variable width, height : natural;
  begin
    read_jpeg(G_INPUT, pixels, width, height);
    write_frame(G_OUTPUT, pixels, width, height);
    deallocate(pixels);
    std.env.finish;
    wait;
  end process;
end;
