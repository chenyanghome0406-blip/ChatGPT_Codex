# MATLAB 實證分析一鍵流程（可客製 methodology）

本專案提供可重現、可驗證、可投稿導向（JBF/FRL）的 MATLAB 實證分析流程。

## 你可以做的事

- 直接讀取 Excel (`input/data.xlsx`)
- 逐步輸出每個分析步驟的原始結果檔
- 支援：
  - OLS
  - 固定效果（以類別虛擬變數方式）
  - 叢聚標準誤（cluster-robust SE）
  - IV/2SLS（可選）
  - DID（可選）
- 自動產生 `JBF_FRL_empirical_report_draft.md`
- 整合既有成果報告內容（`input/current_report.md`）

## 使用方式

1. 準備資料：`input/data.xlsx`
2. （可選）準備方法設定：`input/methodology_config.json`
3. （可選）放入既有報告：`input/current_report.md`
4. 在 MATLAB 執行：

```matlab
run('run_empirical_analysis.m')
```

## 設定檔（可選）範例

建立 `input/methodology_config.json`：

```json
{
  "sheet": 1,
  "cluster_var": "FirmID",
  "fe_vars": ["Year"],
  "winsor": [1, 99],
  "vars": {
    "date": "Date",
    "id": "FirmID",
    "y": "Y",
    "x": ["X1", "X2", "X3"],
    "controls": ["Size", "Leverage"]
  },
  "iv": {
    "enabled": true,
    "endog_var": "X1",
    "instrument_var": "Z1",
    "exog_vars": ["X2", "X3"]
  },
  "did": {
    "enabled": true,
    "treat_var": "Treat",
    "post_var": "Post"
  }
}
```

## 輸出內容

每次執行會建立：`output/<timestamp>/`

- `step_outputs/step0_input_excel_snapshot.xlsx`
- `step_outputs/step1_raw_import.csv` / `.mat`
- `step_outputs/step2_cleaned_data.csv` / `step2_missing_summary.csv`
- `step_outputs/step3_descriptive_stats.csv` / 相關矩陣
- `step_outputs/step4_baseline_*.csv`
- `step_outputs/step5_*.csv`（穩健性）
- `step_outputs/step6_*.csv`（IV 或 DID 啟用時）
- `figures/`（殘差圖）
- `run_log.txt`
- `all_generated_files.csv`
- `JBF_FRL_empirical_report_draft.md`

## 注意

- 若欄位名稱不同，請透過 `methodology_config.json` 或程式內預設值調整。
- IV/2SLS、DID 為可選模組，只有設定 `enabled: true` 才執行。
