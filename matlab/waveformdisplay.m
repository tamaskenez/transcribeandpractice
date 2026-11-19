% Load audio file, make mono mix
[Y, fs] = audioread('/Users/tamas/Desktop/bubble chorus.mp3');
Y = sum(Y, 2) / 2;

% We're going to display it from a to b
a = 50000;
b = 200000;

% Render it into a (h, w) matrix
w = 1500;
h = 150;
M = zeros(h, w);
N1 = 100;
N2 = 10000;
for i = 1:N1
    % Random sampling along time
    ra = rand(N2, 1);
    r = ra * (b - a) + a;
    r0 = floor(r);
    rf = r - r0;
    % Linear-interpolate sample value
    ry = Y(r0) + (Y(r0 + 1)  - Y(r0)) .* rf;

    % Map to display coordinates
    tx = ra * (w - 2) + 1;
    txf = floor(tx);
    txt = tx - txf;
    ty = ry * (h - 2) / 2 + h / 2;
    tyf = floor(ty);
    tyt = ty - tyf;

    % Bilinear-interpolated point at sample location
    % (accumarray sums contributions that land on the same pixel)
    rows = [tyf; tyf + 1; tyf;     tyf + 1];
    cols = [txf; txf;     txf + 1; txf + 1];
    vals = [(1 - tyt) .* (1 - txt); tyt .* (1 - txt); (1 - tyt) .* txt; tyt .* txt];
    M = M + accumarray([rows cols], vals, [h w]);
end

g = gausswin(5);
g = g / sum(g);
MM = conv2(M, g * g');
l = 10 * N1 * N2 / (b - a);
MM(MM>l) = l;
imagesc(MM)
