// definitions/sources/kol_sources.js

// Terraformのrelease_configから渡される 'source_schema' 変数を直接使用します。
// これにより、実行環境（prd/stg）に応じて適切なソーススキーマ（kolbi_keiba/kolbi_keiba_stg）が動的に選択されます。
const { source_schema } = dataform.projectConfig.vars;

// kolbi_keiba
declare({
  schema: source_schema,
  name: "kol_den1"
});

declare({
  schema: source_schema,
  name: "kol_den2"
});

declare({
  schema: source_schema,
  name: "kol_sei1"
});

declare({
  schema: source_schema,
  name: "kol_sei2"
});

declare({
  schema: source_schema,
  name: "kol_com1"
});

declare({
  schema: source_schema,
  name: "kol_uma_ketto"
});