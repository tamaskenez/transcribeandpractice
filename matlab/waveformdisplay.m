% Load audio file, make mono mix
%[Y, fs] = audioread('/Users/tamas/Desktop/bubble chorus.mp3');
[Y, fs] = audioread('/Users/tamas/Desktop/bubble1.mp3');
Y = sum(Y, 2) / 2;
%Y = repmat([.5 -.5]', 5000000, 1);

% We're going to display it around c
c = 200000;

% Render it into a (h, w) matrix
w = 2000;
h = 600;
M = zeros(h, w);

zoom = 1/100;
L = (w - h) / zoom;
a = round(c - L/2);
b = round(c + L/2);

printf("ab: %d %d\n", a, b);
assert(1 <= a && b <= length(Y));

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
    % vals = vals .* repmat(0.4 + abs(ry), 4, 1);
    M = M + accumarray([rows cols], vals, [h w]);
end

g = gausswin(5);
g = g * g';
g = g / sum(g(:));
MM = conv2(M, g) / (N1 * N2) * w * h / 50;
%l = 1;
%MM(MM>l) = l;
figure(1), imagesc(MM, [0 1])
% figure(1), imagesc(MM)
figure(2), hist(MM(:));
