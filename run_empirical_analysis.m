%% run_empirical_analysis.m
% 依據 methodology 設定檔，對 Excel 資料執行可重現實證分析。
% 每一步都會輸出可驗證的原始結果檔案，並自動生成投稿導向報告草稿。
%
% 使用方式
% 1) 放置資料：input/data.xlsx
% 2) 放置設定：input/methodology_config.json（可選，沒有就用預設）
% 3) 放置現有報告：input/current_report.md（可選）
% 4) MATLAB 執行：run('run_empirical_analysis.m')

clear; clc;

%% 0) Config
cfg = defaultConfig();
configPath = fullfile('input', 'methodology_config.json');
if exist(configPath, 'file') == 2
    cfg = mergeConfig(cfg, jsondecode(fileread(configPath)));
end

timestamp = datestr(now, 'yyyymmdd_HHMMSS');
outDir = fullfile(cfg.output_root, timestamp);
mkdirIfNeeded(cfg.output_root);
mkdirIfNeeded(outDir);
mkdirIfNeeded(fullfile(outDir, 'step_outputs'));
mkdirIfNeeded(fullfile(outDir, 'figures'));

copyfileSafe(cfg.input_excel, fullfile(outDir, 'step_outputs', 'step0_input_excel_snapshot.xlsx'));
if exist(configPath, 'file') == 2
    copyfileSafe(configPath, fullfile(outDir, 'step_outputs', 'step0_methodology_config_snapshot.json'));
end

diary(fullfile(outDir, 'run_log.txt'));
disp('=== Empirical Analysis Pipeline Start ===');
disp(['Timestamp: ', datestr(now)]);

%% 1) Data import
assert(exist(cfg.input_excel, 'file') == 2, ['找不到資料檔：', cfg.input_excel]);
T = readtable(cfg.input_excel, 'Sheet', cfg.sheet);
writetable(T, fullfile(outDir, 'step_outputs', 'step1_raw_import.csv'));
save(fullfile(outDir, 'step_outputs', 'step1_raw_import.mat'), 'T');
fprintf('Step1 讀取完成：%d 筆、%d 欄\n', height(T), width(T));

%% 2) Data cleaning + variable construction
varsNeeded = unique([{cfg.vars.date, cfg.vars.id, cfg.vars.y}, cfg.vars.x, cfg.vars.controls]);
if cfg.did.enabled
    varsNeeded = unique([varsNeeded, {cfg.did.treat_var, cfg.did.post_var}]);
end
if cfg.iv.enabled
    varsNeeded = unique([varsNeeded, {cfg.iv.endog_var, cfg.iv.instrument_var}, cfg.iv.exog_vars]);
end

missingVars = setdiff(varsNeeded, T.Properties.VariableNames);
assert(isempty(missingVars), ['缺少欄位: ', strjoin(missingVars, ', ')]);

U = T(:, varsNeeded);
if ~isdatetime(U.(cfg.vars.date))
    U.(cfg.vars.date) = parseDatetime(U.(cfg.vars.date));
end
if cfg.create_year_from_date && isdatetime(U.(cfg.vars.date))
    U.Year = year(U.(cfg.vars.date));
end

missTbl = missingSummary(U);
preN = height(U);
U = rmmissing(U);
postN = height(U);

writetable(missTbl, fullfile(outDir, 'step_outputs', 'step2_missing_summary.csv'));
writetable(U, fullfile(outDir, 'step_outputs', 'step2_cleaned_data.csv'));
fprintf('Step2 清理完成：%d -> %d\n', preN, postN);

%% 3) Descriptive stats + correlation
numVars = unique([{cfg.vars.y}, cfg.vars.x, cfg.vars.controls]);
D = U(:, numVars);

desc = descriptiveStats(D);
writetable(desc, fullfile(outDir, 'step_outputs', 'step3_descriptive_stats.csv'));

[R, P] = corr(table2array(D), 'Rows', 'pairwise');
Rtbl = array2table(R, 'VariableNames', numVars, 'RowNames', numVars);
Ptbl = array2table(P, 'VariableNames', numVars, 'RowNames', numVars);
writetable(Rtbl, fullfile(outDir, 'step_outputs', 'step3_corr_matrix.csv'), 'WriteRowNames', true);
writetable(Ptbl, fullfile(outDir, 'step_outputs', 'step3_corr_pvalues.csv'), 'WriteRowNames', true);
fprintf('Step3 描述統計與相關分析完成\n');

%% 4) Baseline model (OLS/FE + cluster SE)
baseRegressors = unique([cfg.vars.x, cfg.vars.controls]);
base = runLinearModel(U, cfg.vars.y, baseRegressors, cfg.fe_vars, cfg.cluster_var);

writetable(base.coef, fullfile(outDir, 'step_outputs', 'step4_baseline_coefficients.csv'));
writetable(base.fittedResid, fullfile(outDir, 'step_outputs', 'step4_baseline_fitted_residuals.csv'));
writetable(base.designInfo, fullfile(outDir, 'step_outputs', 'step4_baseline_design_columns.csv'));

f1 = figure('Visible', 'off');
scatter(base.fittedResid.Fitted, base.fittedResid.Residual, 8, 'filled');
yline(0, '--k'); xlabel('Fitted'); ylabel('Residual'); title('Baseline Residual vs Fitted');
exportgraphics(f1, fullfile(outDir, 'figures', 'step4_baseline_resid_vs_fitted.png'));
close(f1);
fprintf('Step4 基準模型完成 (R2=%.4f)\n', base.metrics.R2);

%% 5) Robustness
% 5A winsorization
Uw = U;
for i = 1:numel(numVars)
    v = numVars{i};
    Uw.(v) = winsorizeVec(Uw.(v), cfg.winsor(1), cfg.winsor(2));
end
winsorModel = runLinearModel(Uw, cfg.vars.y, baseRegressors, cfg.fe_vars, cfg.cluster_var);
writetable(winsorModel.coef, fullfile(outDir, 'step_outputs', 'step5_winsor_coefficients.csv'));

% 5B subsample split by median(Y)
medY = median(U.(cfg.vars.y));
U_hi = U(U.(cfg.vars.y) >= medY, :);
U_lo = U(U.(cfg.vars.y) < medY, :);
subHi = runLinearModel(U_hi, cfg.vars.y, baseRegressors, cfg.fe_vars, cfg.cluster_var);
subLo = runLinearModel(U_lo, cfg.vars.y, baseRegressors, cfg.fe_vars, cfg.cluster_var);
writetable(subHi.coef, fullfile(outDir, 'step_outputs', 'step5_subsample_high_coefficients.csv'));
writetable(subLo.coef, fullfile(outDir, 'step_outputs', 'step5_subsample_low_coefficients.csv'));
fprintf('Step5 穩健性完成\n');

%% 6) Optional models
ivOut = [];
if cfg.iv.enabled
    ivOut = runIV2SLS(U, cfg, cfg.fe_vars, cfg.cluster_var);
    writetable(ivOut.stage1.coef, fullfile(outDir, 'step_outputs', 'step6_iv_stage1_coefficients.csv'));
    writetable(ivOut.stage2.coef, fullfile(outDir, 'step_outputs', 'step6_iv_stage2_coefficients.csv'));
    writetable(ivOut.stage2.fittedResid, fullfile(outDir, 'step_outputs', 'step6_iv_stage2_fitted_residuals.csv'));
    fprintf('Step6 IV/2SLS 完成\n');
end

didOut = [];
if cfg.did.enabled
    didOut = runDID(U, cfg, cfg.fe_vars, cfg.cluster_var);
    writetable(didOut.coef, fullfile(outDir, 'step_outputs', 'step6_did_coefficients.csv'));
    writetable(didOut.fittedResid, fullfile(outDir, 'step_outputs', 'step6_did_fitted_residuals.csv'));
    fprintf('Step6 DID 完成\n');
end

%% 7) Report draft generation
reportPath = fullfile(outDir, 'JBF_FRL_empirical_report_draft.md');
reportTxt = buildReportDraft(cfg, desc, base, winsorModel, subHi, subLo, ivOut, didOut, outDir);

currentReportPath = fullfile('input', 'current_report.md');
if exist(currentReportPath, 'file') == 2
    reportTxt = reportTxt + newline + "## Appendix: Integrated Existing Report" + newline + fileread(currentReportPath);
end

fid = fopen(reportPath, 'w', 'n', 'UTF-8');
fprintf(fid, '%s', reportTxt);
fclose(fid);

%% 8) Manifest
files = dir(fullfile(outDir, '**', '*'));
files = files(~[files.isdir]);
manifest = table(string(fullfile({files.folder}, {files.name}))', 'VariableNames', {'FilePath'});
writetable(manifest, fullfile(outDir, 'all_generated_files.csv'));

disp('=== Pipeline completed successfully ===');
fprintf('Output: %s\n', outDir);
diary off;

%% ===== Local functions =====
function cfg = defaultConfig()
cfg.input_excel = fullfile('input', 'data.xlsx');
cfg.sheet = 1;
cfg.output_root = 'output';
cfg.create_year_from_date = true;
cfg.winsor = [1, 99];
cfg.cluster_var = 'FirmID';
cfg.fe_vars = {'Year'};

cfg.vars.date = 'Date';
cfg.vars.id = 'FirmID';
cfg.vars.y = 'Y';
cfg.vars.x = {'X1', 'X2', 'X3'};
cfg.vars.controls = {};

cfg.iv.enabled = false;
cfg.iv.endog_var = '';
cfg.iv.instrument_var = '';
cfg.iv.exog_vars = {};

cfg.did.enabled = false;
cfg.did.treat_var = '';
cfg.did.post_var = '';
end

function cfg = mergeConfig(cfg, j)
fn = fieldnames(j);
for i = 1:numel(fn)
    key = fn{i};
    if isstruct(j.(key)) && isfield(cfg, key)
        cfg.(key) = mergeConfig(cfg.(key), j.(key));
    else
        cfg.(key) = j.(key);
    end
end
end

function mkdirIfNeeded(p)
if exist(p, 'dir') ~= 7
    mkdir(p);
end
end

function copyfileSafe(src, dst)
if exist(src, 'file') == 2
    copyfile(src, dst);
end
end

function dt = parseDatetime(x)
if isdatetime(x)
    dt = x;
elseif isnumeric(x)
    dt = datetime(x, 'ConvertFrom', 'excel');
else
    dt = datetime(string(x));
end
end

function tbl = missingSummary(T)
vars = T.Properties.VariableNames;
miss = zeros(numel(vars), 1);
for i = 1:numel(vars)
    miss(i) = sum(ismissing(T.(vars{i})));
end
tbl = table(string(vars)', miss, miss ./ height(T), 'VariableNames', {'Variable', 'MissingCount', 'MissingRate'});
end

function desc = descriptiveStats(T)
vars = T.Properties.VariableNames;
n = numel(vars);
desc = table('Size', [n, 9], ...
    'VariableTypes', {'string','double','double','double','double','double','double','double','double'}, ...
    'VariableNames', {'Variable','N','Mean','Std','P25','Median','P75','Min','Max'});
for i = 1:n
    x = T.(vars{i});
    desc.Variable(i) = string(vars{i});
    desc.N(i) = sum(~isnan(x));
    desc.Mean(i) = mean(x);
    desc.Std(i) = std(x);
    desc.P25(i) = prctile(x, 25);
    desc.Median(i) = median(x);
    desc.P75(i) = prctile(x, 75);
    desc.Min(i) = min(x);
    desc.Max(i) = max(x);
end
end

function out = runLinearModel(T, yVar, xVars, feVars, clusterVar)
[y, X, varNames, keepIdx] = buildDesignMatrix(T, yVar, xVars, feVars);
cluster = [];
if ~isempty(clusterVar) && ismember(clusterVar, T.Properties.VariableNames)
    cluster = T.(clusterVar);
    cluster = cluster(keepIdx);
end

est = olsEstimate(y, X, varNames, cluster);
out.coef = est.coef;
out.metrics = est.metrics;
out.designInfo = table(string(varNames)', 'VariableNames', {'DesignColumn'});
out.fittedResid = table(y, est.fitted, est.resid, 'VariableNames', {'Y', 'Fitted', 'Residual'});
out.keepIdx = keepIdx;
end

function [y, X, names, keep] = buildDesignMatrix(T, yVar, xVars, feVars)
V = T(:, unique([{yVar}, xVars, feVars]));
keep = all(~ismissing(V), 2);
V = V(keep, :);

y = V.(yVar);
X = ones(height(V), 1);
names = {'Intercept'};

for i = 1:numel(xVars)
    X = [X, V.(xVars{i})];
    names{end+1} = xVars{i}; %#ok<AGROW>
end

for i = 1:numel(feVars)
    f = feVars{i};
    c = categorical(V.(f));
    D = dummyvar(c);
    if size(D,2) > 1
        D = D(:,2:end);
        cats = categories(c);
        cats = cats(2:end);
        for k = 1:numel(cats)
            names{end+1} = [f, '_FE_', char(cats{k})]; %#ok<AGROW>
        end
        X = [X, D];
    end
end
end

function est = olsEstimate(y, X, varNames, cluster)
n = size(X,1);
k = size(X,2);
invXX = inv(X' * X);
b = invXX * (X' * y);
fitted = X * b;
resid = y - fitted;

% variance
if isempty(cluster)
    s2 = (resid' * resid) / (n - k);
    V = s2 * invXX;
else
    [~, ~, g] = unique(cluster);
    G = max(g);
    S = zeros(k, k);
    for i = 1:G
        idx = (g == i);
        Xi = X(idx,:);
        ui = resid(idx);
        S = S + (Xi' * (ui * ui') * Xi);
    end
    dfc = (G/(G-1)) * ((n-1)/(n-k));
    V = dfc * invXX * S * invXX;
end

se = sqrt(diag(V));
tv = b ./ se;
pv = 2 * (1 - tcdf(abs(tv), n-k));

sst = sum((y - mean(y)).^2);
ssr = sum(resid.^2);
r2 = 1 - ssr/sst;
adjr2 = 1 - (1-r2)*(n-1)/(n-k);

coef = table(string(varNames)', b, se, tv, pv, 'VariableNames', ...
    {'Variable', 'Coefficient', 'StdError', 'tStat', 'pValue'});

metrics = struct();
metrics.N = n;
metrics.K = k;
metrics.R2 = r2;
metrics.AdjR2 = adjr2;

est.coef = coef;
est.metrics = metrics;
est.fitted = fitted;
est.resid = resid;
end

function xw = winsorizeVec(x, pLow, pHigh)
lo = prctile(x, pLow);
hi = prctile(x, pHigh);
xw = min(max(x, lo), hi);
end

function out = runIV2SLS(U, cfg, feVars, clusterVar)
% stage 1: endog ~ instrument + exog + FE
x1 = unique([{cfg.iv.instrument_var}, cfg.iv.exog_vars, cfg.vars.controls, cfg.vars.x]);
stage1 = runLinearModel(U, cfg.iv.endog_var, x1, feVars, clusterVar);

U2 = U;
xhat = nan(height(U), 1);
xhat(stage1.keepIdx) = stage1.fittedResid.Fitted;
U2.([cfg.iv.endog_var, '_hat']) = xhat;

% stage 2: y ~ endog_hat + exog + FE
x2 = unique([{[cfg.iv.endog_var, '_hat']}, cfg.iv.exog_vars, cfg.vars.controls, cfg.vars.x]);
stage2 = runLinearModel(U2, cfg.vars.y, x2, feVars, clusterVar);

out.stage1 = stage1;
out.stage2 = stage2;
end

function out = runDID(U, cfg, feVars, clusterVar)
U2 = U;
intName = [cfg.did.treat_var, '_x_', cfg.did.post_var];
U2.(intName) = U2.(cfg.did.treat_var) .* U2.(cfg.did.post_var);

x = unique([{cfg.did.treat_var, cfg.did.post_var, intName}, cfg.vars.controls, cfg.vars.x]);
out = runLinearModel(U2, cfg.vars.y, x, feVars, clusterVar);
end

function txt = buildReportDraft(cfg, desc, base, winM, hiM, loM, ivOut, didOut, outDir)
txt = "# Empirical Analysis Report (JBF/FRL-ready Draft)" + newline + ...
"" + newline + ...
"## 1. Abstract" + newline + ...
"This report integrates the current methodology and produces fully reproducible outputs for each empirical step." + newline + newline + ...
"## 2. Data and Methodology" + newline + ...
"- Input Excel: `" + cfg.input_excel + "`" + newline + ...
"- Dependent variable: `" + cfg.vars.y + "`" + newline + ...
"- Key regressors: `" + strjoin(cfg.vars.x, ', ') + "`" + newline + ...
"- Controls: `" + strjoin(cfg.vars.controls, ', ') + "`" + newline + ...
"- Fixed effects: `" + strjoin(cfg.fe_vars, ', ') + "`" + newline + ...
"- Cluster variable: `" + cfg.cluster_var + "`" + newline + newline + ...
"## 3. Main Results" + newline + ...
"### 3.1 Baseline" + newline + ...
"- N = " + string(base.metrics.N) + ", R2 = " + string(base.metrics.R2) + ", Adj-R2 = " + string(base.metrics.AdjR2) + newline + ...
"- See: `step4_baseline_coefficients.csv`" + newline + newline + ...
"### 3.2 Robustness" + newline + ...
"- Winsorized model R2 = " + string(winM.metrics.R2) + newline + ...
"- Subsample-high R2 = " + string(hiM.metrics.R2) + newline + ...
"- Subsample-low R2 = " + string(loM.metrics.R2) + newline + newline;

if ~isempty(ivOut)
    txt = txt + "### 3.3 IV/2SLS" + newline + ...
    "- Stage1 R2 = " + string(ivOut.stage1.metrics.R2) + newline + ...
    "- Stage2 R2 = " + string(ivOut.stage2.metrics.R2) + newline + newline;
end

if ~isempty(didOut)
    txt = txt + "### 3.4 DID" + newline + ...
    "- DID model R2 = " + string(didOut.metrics.R2) + newline + newline;
end

txt = txt + ...
"## 4. Manuscript-ready Narrative (Template)" + newline + ...
"1) Explain economic mechanism and hypothesis mapping for each coefficient." + newline + ...
"2) Compare signs/magnitudes with top-tier JBF/FRL references." + newline + ...
"3) Add endogeneity discussion and identification assumptions." + newline + newline + ...
"## 5. Reproducibility" + newline + ...
"- All outputs are located at: `" + outDir + "`" + newline + ...
"- Full file index: `all_generated_files.csv`" + newline + newline + ...
"## 6. Descriptive statistics snapshot" + newline + ...
string(evalc('disp(desc)')) + newline;
end
