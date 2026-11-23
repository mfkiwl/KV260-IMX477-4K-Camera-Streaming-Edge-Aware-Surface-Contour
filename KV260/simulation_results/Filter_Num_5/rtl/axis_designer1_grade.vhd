library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;

-- RGB888 filmic grade. A single scalar exposure curve is shared by all three
-- channels. Colour and saturation are calculated from the incoming R-G and G-B.
entity axis_designer1_grade is
  port (
    aclk, aresetn : in std_logic;
    s_axis_tdata : in std_logic_vector(23 downto 0);
    s_axis_tvalid, s_axis_tuser, s_axis_tlast : in std_logic;
    s_axis_tready : out std_logic;
    m_axis_tdata : out std_logic_vector(23 downto 0);
    m_axis_tvalid, m_axis_tuser, m_axis_tlast : out std_logic;
    m_axis_tready : in std_logic;
    -- Sampled with each input beat. Low selects the camera filter's RGB.
    s_use_designer : in std_logic := '1'
  );
end entity;

architecture rtl of axis_designer1_grade is
  type anchors_t is array (0 to 13) of natural;
  constant LEVELS : anchors_t := (0,32,48,64,80,96,112,128,144,160,176,192,224,256);
  constant EXPOSURE_Q2 : anchors_t := (0,153,195,283,348,429,464,577,671,696,703,735,858,986);
  type exposure_rom_t is array (byte_t) of natural range 0 to 16383;
  function make_exposure return exposure_rom_t is
    variable lut : exposure_rom_t;
    variable width, rise : natural;
  begin
    for k in 0 to 12 loop
      width := LEVELS(k+1)-LEVELS(k);
      rise := 16*(EXPOSURE_Q2(k+1)-EXPOSURE_Q2(k));
      for i in 0 to width-1 loop
        lut(LEVELS(k)+i) := 16*EXPOSURE_Q2(k)+(i*rise+width/2)/width;
      end loop;
    end loop;
    return lut;
  end function;
  constant EXPOSURE : exposure_rom_t := make_exposure;

  -- Q6 coefficients for 15 analytic terms. Their order is given in the
  -- assignment to terms below. Every row operates on the same physical pixel.
  type matrix_t is array (0 to 2, 0 to 14) of integer range -256 to 255;
  constant COEFF : matrix_t := (
    (88, -95,-246,-104, 76,231, 133,-141,105, 50,-116,196, 14, -41,-146),
    (153,-104,-173, -81, 97,141,-124,-191, 41, 62, -63,149, 86, -74, -84),
    (120, -89, -24, -32, 66,-94,  22,-222,-50,153,  10, 19,-45,-139, 160)
  );
  function rounded_q5_product(a,b : integer) return integer is
  begin
    -- All products lie above -4096. The bias implements signed floor rounding.
    return (4096+a*b+16)/32-128;
  end function;

  type terms_t is array (0 to 14) of integer range -128 to 127;
  type products_t is array (0 to 2, 0 to 14) of integer range -32768 to 32767;
  type groups_t is array (0 to 2, 0 to 3) of integer range -131072 to 131071;
  type halves_t is array (0 to 2, 0 to 1) of integer range -262144 to 262143;
  type triple_t is array (0 to 2) of integer range -32768 to 32767;
  type base_pipe_t is array (1 to 4) of triple_t;
  type rgb_pipe_t is array (0 to 5) of rgb_t;
  type weight_pipe_t is array (0 to 5) of natural range 0 to 32;

  signal input_rgb : rgb_pipe_t;
  signal weight : weight_pipe_t;
  signal exposure1 : natural range 0 to 16383;
  signal shadow1, highlight1, mid1 : natural range 0 to 64;
  signal u1, v1 : integer range -64 to 64;
  signal uc1 : integer range -14 to 24;
  signal vc1 : natural range 0 to 40;
  signal diff1 : triple_t;
  signal base : base_pipe_t;
  signal terms : terms_t;
  signal products : products_t;
  signal groups : groups_t;
  signal halves : halves_t;
  signal graded6 : rgb_t;

  signal v, sof, eol : std_logic_vector(0 to 6) := (others=>'0');
  signal advance : std_logic;
begin
  advance <= not v(6) or m_axis_tready;
  s_axis_tready <= aresetn and advance;
  m_axis_tvalid <= v(6); m_axis_tuser <= sof(6); m_axis_tlast <= eol(6);

  grade : process(aclk)
    variable pixel : rgb_t;
    variable y, u, vb, span, level : integer;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        v <= (others=>'0'); sof <= (others=>'0'); eol <= (others=>'0');
        m_axis_tdata <= (others=>'0');
      elsif advance='1' then
        v <= s_axis_tvalid & v(0 to 5);
        sof <= s_axis_tuser & sof(0 to 5);
        eol <= s_axis_tlast & eol(0 to 5);

        -- Stage 0. Return smoothly to input RGB at extreme exposure or chroma.
        if s_axis_tvalid='1' then
          pixel := unpack(to_integer(unsigned(s_axis_tdata)));
          y := luma(pixel); u := pixel(0)-pixel(1); vb := pixel(1)-pixel(2);
          span := largest(pixel(0),largest(pixel(1),pixel(2)))
                  -smallest(pixel(0),smallest(pixel(1),pixel(2)));
          if s_use_designer='1' then
            weight(0) <= clamp(smallest(y-16,smallest(240-y,128-span)),0,32);
          else
            weight(0) <= 0;
          end if;
          input_rgb(0) <= pixel;
          for ch in 0 to 2 loop diff1(ch) <= pixel(ch)-y; end loop;
          exposure1 <= EXPOSURE(y);
          shadow1 <= clamp(128-y,0,64);
          highlight1 <= clamp(y-112,0,64);
          mid1 <= clamp(y-48,0,48)-clamp(y-96,0,48);
          u1 <= clamp(u,-48,48); v1 <= clamp(vb,-64,64);
          uc1 <= clamp(u,-14,24); vc1 <= clamp(vb,0,40);
        end if;

        -- Stage 1. The bounded products adapt saturation to exposure and input chroma.
        if v(0)='1' then
          terms <= (32,shadow1,highlight1,mid1,u1,v1,uc1,vc1,
                    rounded_q5_product(shadow1,uc1), rounded_q5_product(shadow1,vc1),
                    rounded_q5_product(highlight1,uc1), rounded_q5_product(highlight1,vc1),
                    rounded_q5_product(uc1,v1), rounded_q5_product(uc1,u1),
                    rounded_q5_product(vc1,v1));
          for ch in 0 to 2 loop base(1)(ch) <= exposure1+64*diff1(ch); end loop;
        end if;
        for k in 1 to 5 loop
          input_rgb(k) <= input_rgb(k-1);
          weight(k) <= weight(k-1);
        end loop;
        for k in 2 to 4 loop base(k) <= base(k-1); end loop;

        for ch in 0 to 2 loop
          -- Stages 2 through 4. Balanced, registered sum of Q6 terms.
          if v(1)='1' then
            for i in terms'range loop products(ch,i) <= COEFF(ch,i)*terms(i); end loop;
          end if;
          if v(2)='1' then
            for g in 0 to 2 loop
              groups(ch,g) <= (products(ch,4*g)+products(ch,4*g+1))
                              +(products(ch,4*g+2)+products(ch,4*g+3));
            end loop;
            groups(ch,3) <= products(ch,12)+products(ch,13)+products(ch,14);
          end if;
          if v(3)='1' then
            halves(ch,0) <= groups(ch,0)+groups(ch,1);
            halves(ch,1) <= groups(ch,2)+groups(ch,3);
          end if;
          -- Stages 5 and 6. Saturate the grade, then blend at the gamut limits.
          if v(4)='1' then
            level := base(4)(ch)+halves(ch,0)+halves(ch,1);
            graded6(ch) <= clamp(level+32,0,255*64)/64;
          end if;
          if v(5)='1' then
            level := (weight(5)*graded6(ch)+(32-weight(5))*input_rgb(5)(ch)+16)/32;
            m_axis_tdata(23-8*ch downto 16-8*ch) <= std_logic_vector(to_unsigned(level,8));
          end if;
        end loop;
      end if;
    end if;
  end process;
end architecture;
