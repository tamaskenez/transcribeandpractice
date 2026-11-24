fs = 48000;
N = 5000;
ns = [0:N-1]';
f = 500;
x = cos(2 * pi * f / fs * ns) + 0 * cos(2 * pi * 2 * f / fs * ns);
x(1:floor(N/3)) = 0;
x(floor(2*N/3):end) = 0;
x = x + randn(size(x)) * 0.04;
L = 501;
H = (L-1)/2;
c = 2000;
w = gausswin(L);
xw = x;
a = c - H;
b = c + H;
xw(1:a-1) = 0;
xw(a:b) = x(a:b) .* w;
xw(b+1:end) = 0;
figure(1);
plot(ns, x, ns, xw), grid;

cs = 1000:4000;
M = zeros(f*2, length(cs));
for c = cs
    xw = x;
    a = c - H;
    b = c + H;
    xw(1:a-1) = 0;
    xw(a:b) = x(a:b) .* w;
    xw(b+1:end) = 0;
    fxw = fft(xw, fs);
    M(:, c - cs(1) + 1) = fxw(1:f*2);
end
figure(2);imagesc(abs(M))
kn = 1200;
kf = 500;

d_arg_M_dt = diff(unwrap(angle(M), pi, 2), 1, 2);
d_arg_M_df = diff(unwrap(angle(M)));

figure(3);
subplot(2,1,1);
plot(0:2*f-1, abs(M(:, kn))), grid;
title('mag across freq at time');
subplot(2,1,2);
plot(0:2*f-1, d_arg_M_dt(:, kn)), grid
title('d_arg_M_dt across freq at time');

figure(4);
subplot(2,1,1);
plot(1:size(M, 2), abs(M(kf, :))), grid;
title('mag at freq across time');
subplot(2,1,2);
plot(1:size(M,2), d_arg_M_df(kf, :)), grid;
title('d_arg_M_df at freq across time');



