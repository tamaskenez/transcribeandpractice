fs=48000;
L = 13;
HL = (L-1) / 2;
n = [-HL:HL]';
fc = fs/4;
A = 2*fc/fs;
oc = A * pi;

w2 = sinc(oc * n / pi) .* hamming(L);
w2(abs(w2) < 1e-15) = 0;
w2 = w2 / sum(w2);
w3 = [-1 0 9 16 9 0 -1];
w3 = w3 / sum(w3);

w = w2;

wx = blackman(fs);
wx = wx / sum(wx);

xc = [];
for f = 0:157:fs/2
    fsd = fs;
    x = cos(2*pi*f/fs*[0:fs-1]') .* wx;
    for i = 1:5
        x = conv(x, w, 'same');
        x = 2 * x(1:2:end);
        fsd = fsd / 2;
    end
    if f == 0
        xc = x;
    else
        xc = xc + x;
    end
end

fx = fft(xc, fsd);
plot([0:fsd-1]', mag2db(abs(fx)));
axis([0 fsd/2 -40 0]), grid;
