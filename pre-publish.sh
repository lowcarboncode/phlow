#!/bin/bash
set -euo pipefail

# Diretórios base
RELEASE_DIR="target/release"
DEST_DIR=".tmp/modules"
PACKAGE_DIR=".tmp/packages"
FINAL_DIR="packages"
INDEXS_DIR="indexs"

# Argumentos CLI
MODULES_DIR="modules"

while [[ $# -gt 0 ]]; do
  case $1 in
    --dir)
      MODULES_DIR="$2"
      shift 2
      ;;
    *)
      echo "Uso: $0 [--dir <diretório_de_módulos>]"
      exit 1
      ;;
  esac
done

echo "Usando diretório de módulos: $MODULES_DIR"

# Garante diretórios existentes
mkdir -p "$DEST_DIR" "$PACKAGE_DIR" "$FINAL_DIR"

# Verifica se jq está instalado
command -v jq >/dev/null 2>&1 || {
    echo >&2 "Erro: 'jq' não está instalado."
    exit 1
}

# Gera caminho com 4 primeiros caracteres em pares de 2, completando com "_"
build_path_from_name() {
    local name=$1
    local padded_name="${name}____"
    local part1="${padded_name:0:2}"
    local part2="${padded_name:2:2}"
    echo "$part1/$part2"
}

# Função para extrair versão
get_version() {
    local file=$1
    local ext=$2
    if [[ "$ext" == "json" ]]; then
        jq -r '.version // empty' "$file"
    else
        grep '^version:' "$file" | sed 's/version:[[:space:]]*//'
    fi
}

# Função para atualizar ou criar o index.json do pacote
update_index() {
    local module_dir=$1
    local archive_name=$2
    local props_file=""
    local name=""
    local version=""
    local repository=""

    for ext in yaml yml json; do
        test_file="$module_dir/phlow.$ext"
        if [ -f "$test_file" ]; then
            props_file="$test_file"
            break
        fi
    done

    [ -z "$props_file" ] && echo "Arquivo phlow não encontrado em $module_dir" && return

    if [[ "$props_file" == *.json ]]; then
        name=$(jq -r '.name // empty' "$props_file")
        version=$(jq -r '.version // empty' "$props_file")
        repository=$(jq -r '.repository // empty' "$props_file")
    else
        name=$(grep '^name:' "$props_file" | sed 's/name:[[:space:]]*//')
        version=$(grep '^version:' "$props_file" | sed 's/version:[[:space:]]*//')
        repository=$(grep '^repository:' "$props_file" | sed 's/repository:[[:space:]]*//')
    fi

    if [[ -z "$name" || -z "$version" || -z "$repository" ]]; then
        echo "Erro ao extrair metadados de $props_file"
        return
    fi

    index_path="$INDEXS_DIR/$(build_path_from_name "$name")"
    mkdir -p "$index_path"
    index_file="$index_path/${name}.json"



    if [ ! -f "$index_file" ]; then
        echo "[]" > "$index_file"
    fi

    new_entry=$(jq -n \
        --arg version "$version" \
        --arg repository "$repository" \
        --arg archive "$archive_name" \
        '{version: $version, repository: $repository, archive: $archive}')

    if ! jq -e --arg version "$version" '.[] | select(.version == $version)' "$index_file" >/dev/null; then
        tmp=$(mktemp)
        jq ". + [$new_entry]" "$index_file" > "$tmp" && mv "$tmp" "$index_file"
        echo "Índice atualizado: $index_file"
    else
        echo "Versão $version já existe em $index_file"
    fi
}

echo "Compilando projeto em modo release..."
cargo build --release --locked

shopt -s nullglob
so_files=("$RELEASE_DIR"/lib*.so)

if [ ${#so_files[@]} -eq 0 ]; then
    echo "Nenhum arquivo .so encontrado em $RELEASE_DIR"
    exit 1
fi

# Descobre os módulos a serem processados
module_dirs=()

if compgen -G "$MODULES_DIR/phlow.*" > /dev/null; then
  # Diretório de um único módulo
  single_module=$(basename "$MODULES_DIR")
  module_dirs+=("$single_module")
  SINGLE_MODULE_DIR="$MODULES_DIR"
  MODULES_DIR=".tmp/single"  # diretório temporário para tratar como múltiplos
  mkdir -p "$MODULES_DIR/$single_module"
  cp -r "$SINGLE_MODULE_DIR"/* "$MODULES_DIR/$single_module/"
else
  # Múltiplos módulos
  for d in "$MODULES_DIR"/*; do
    [ -d "$d" ] || continue
    module_dirs+=("$(basename "$d")")
  done
fi

# Processamento dos módulos
for modulename_no_ext in "${module_dirs[@]}"; do
  file="$RELEASE_DIR/lib${modulename_no_ext}.so"
  if [ ! -f "$file" ]; then
      echo "Aviso: Arquivo $file não encontrado. Pulando."
      continue
  fi

  filename=$(basename "$file")
  module_dest_dir="$DEST_DIR/$modulename_no_ext"
  mkdir -p "$module_dest_dir"

  cp "$file" "$module_dest_dir/module.so"
  echo "Copy: $file -> $module_dest_dir/module.so"

  version=""
  found_metadata=false

  for ext in yaml yml json; do
      props_file="$MODULES_DIR/$modulename_no_ext/phlow.$ext"
      if [ -f "$props_file" ]; then
          cp "$props_file" "$module_dest_dir/phlow.$ext"
          echo "Copy: $props_file -> $module_dest_dir/phlow.$ext"
          version=$(get_version "$props_file" "$ext")
          found_metadata=true
          break
      fi
  done

  if [ "$found_metadata" = false ]; then
      echo "Aviso: Nenhum arquivo phlow.{yaml,yml,json} encontrado para $modulename_no_ext"
      continue
  fi

  if [ -z "$version" ]; then
      echo "Erro: Não foi possível extrair a versão de $modulename_no_ext"
      exit 1
  fi

  package_name="${modulename_no_ext}-${version}.tar.gz"
  tar -czf "$PACKAGE_DIR/$package_name" -C "$DEST_DIR" "$modulename_no_ext"
  echo "Pacote criado: $PACKAGE_DIR/$package_name"

  update_index "$module_dest_dir" "$package_name"
done

# Distribuição
echo ""
echo "Distribuindo pacotes..."
for filepath in "$PACKAGE_DIR"/*.tar.gz; do
    [ -e "$filepath" ] || continue
    filename=$(basename "$filepath")
    base_name="${filename%.tar.gz}"
    module_name="${base_name%-*}"

    if [ ${#module_name} -lt 2 ]; then
        echo "Aviso: Nome $module_name muito curto. Pulando."
        continue
    fi

    partial_path=$(build_path_from_name "$module_name")
    current_path="$FINAL_DIR/$partial_path/$module_name"
    mkdir -p "$current_path"

    mv -n "$filepath" "$current_path/"
    echo "Movido: $filepath -> $current_path/"
done

rm -rf "$PACKAGE_DIR" "$DEST_DIR"
echo ""
echo "Processo concluído com sucesso! 🎉"