"""
Obtenção do dataset bruto (Olist Brazilian E-Commerce).

Os CSVs não são versionados no git (~121 MB). Este script os recupera, de forma
que qualquer pessoa consiga rodar o projeto após um `git clone`.

Uso:
    python src/download_data.py                      # baixa do GitHub Release
    python src/download_data.py --from-zip ARQ.ZIP   # usa um zip já baixado
    python src/download_data.py --force              # rebaixa mesmo se já existir

Depende apenas da biblioteca padrão, de propósito: precisa funcionar antes de
`pip install -r requirements.txt`.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

# O console do Windows usa cp1252 por padrão e quebra ao imprimir acentos.
# Sem isto, uma mensagem de erro pode virar UnicodeEncodeError e esconder o
# problema real que ela tentava reportar.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

REPO = "albuquerques/sales-intelligence-platform"
RELEASE_TAG = "data-v1"
ASSET_NAME = "olist-dataset.zip"
RELEASE_URL = f"https://github.com/{REPO}/releases/download/{RELEASE_TAG}/{ASSET_NAME}"

KAGGLE_URL = "https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce"

PROJECT_ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = PROJECT_ROOT / "data" / "raw"
MANIFEST_PATH = PROJECT_ROOT / "data" / "manifest.json"

# Os 9 arquivos que compõem o dataset. Serve como checagem de completude:
# se algum faltar, a carga falha depois — melhor detectar aqui.
EXPECTED_FILES = [
    "olist_customers_dataset.csv",
    "olist_geolocation_dataset.csv",
    "olist_order_items_dataset.csv",
    "olist_order_payments_dataset.csv",
    "olist_order_reviews_dataset.csv",
    "olist_orders_dataset.csv",
    "olist_products_dataset.csv",
    "olist_sellers_dataset.csv",
    "product_category_name_translation.csv",
]


def _sha256(path: Path) -> str:
    """Hash do arquivo lido em blocos, para não carregar 59 MB na memória."""
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def missing_files() -> list[str]:
    return [name for name in EXPECTED_FILES if not (RAW_DIR / name).exists()]


def _report(done: int, total: int) -> None:
    if total <= 0:
        sys.stdout.write(f"\r  {done / 1024 / 1024:.1f} MB")
    else:
        pct = done * 100 // total
        sys.stdout.write(f"\r  {pct:3d}%  ({done / 1024 / 1024:.1f} / {total / 1024 / 1024:.1f} MB)")
    sys.stdout.flush()


def download(url: str, dest: Path) -> None:
    print(f"Baixando {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "sales-intelligence-platform"})
    with urllib.request.urlopen(req) as resp, dest.open("wb") as out:
        total = int(resp.headers.get("Content-Length", 0))
        done = 0
        while chunk := resp.read(1024 * 256):
            out.write(chunk)
            done += len(chunk)
            _report(done, total)
    print()


def extract(zip_path: Path) -> None:
    """
    Extrai os CSVs para data/raw/ de forma achatada.

    O zip do Kaggle traz os arquivos na raiz, mas um zip remontado à mão pode
    trazer uma pasta por volta — por isso usamos apenas o nome final do arquivo
    e ignoramos qualquer estrutura de diretório.
    """
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    wanted = set(EXPECTED_FILES)
    found = 0

    with zipfile.ZipFile(zip_path) as zf:
        for member in zf.infolist():
            name = Path(member.filename).name
            if name not in wanted or member.is_dir():
                continue
            with zf.open(member) as src, (RAW_DIR / name).open("wb") as dst:
                shutil.copyfileobj(src, dst)
            found += 1
            print(f"  extraido  {name}")

    print(f"{found} de {len(EXPECTED_FILES)} arquivos extraidos para {RAW_DIR}")


def validate() -> bool:
    """
    Confere os arquivos contra data/manifest.json (SHA256 + tamanho).

    O manifesto é gerado por src/make_sample.py. Se ainda não existir, a
    validação é pulada — não é motivo para falhar.
    """
    if not MANIFEST_PATH.exists():
        print("Manifesto ausente (data/manifest.json) — validacao de integridade pulada.")
        return True

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    entries = manifest.get("files", {})
    problems = []

    print("Validando integridade contra o manifesto...")
    for name, meta in entries.items():
        path = RAW_DIR / name
        if not path.exists():
            problems.append(f"{name}: ausente")
            continue
        actual = _sha256(path)
        if actual != meta["sha256"]:
            problems.append(f"{name}: sha256 diverge (esperado {meta['sha256'][:12]}..., obtido {actual[:12]}...)")
        else:
            print(f"  ok  {name}")

    if problems:
        print("\nProblemas de integridade:")
        for p in problems:
            print(f"  - {p}")
        return False

    print("Todos os arquivos conferem com o manifesto.")
    return True


def kaggle_instructions() -> None:
    print(
        f"""
Nao foi possivel baixar do GitHub Release.

Isso e esperado se o release '{RELEASE_TAG}' ainda nao foi publicado.
Baixe o dataset direto da fonte original e aponte o zip para este script:

  1. Acesse: {KAGGLE_URL}
  2. Clique em "Download" (requer login no Kaggle, gratuito)
  3. Rode:  python src/download_data.py --from-zip CAMINHO/DO/archive.zip

Fonte: Olist Brazilian E-Commerce Public Dataset - licenca CC BY-NC-SA 4.0.
""".strip()
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Obtem o dataset bruto do projeto.")
    parser.add_argument("--from-zip", type=Path, help="usa um zip local em vez de baixar")
    parser.add_argument("--force", action="store_true", help="reextrai mesmo se os CSVs ja existirem")
    parser.add_argument("--skip-validation", action="store_true", help="nao confere o manifesto")
    args = parser.parse_args()

    faltando = missing_files()
    if not faltando and not args.force:
        print(f"Dataset ja presente em {RAW_DIR} ({len(EXPECTED_FILES)} arquivos).")
        print("Use --force para reextrair.")
        return 0 if args.skip_validation or validate() else 1

    if args.from_zip:
        zip_path = args.from_zip.expanduser().resolve()
        if not zip_path.exists():
            print(f"Arquivo nao encontrado: {zip_path}")
            return 1
        extract(zip_path)
    else:
        # Baixa para um temporário: se a rede cair no meio, não sobra um zip
        # truncado em data/ que passaria despercebido na próxima execução.
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / ASSET_NAME
            try:
                download(RELEASE_URL, zip_path)
            except (urllib.error.HTTPError, urllib.error.URLError) as exc:
                print(f"Falhou: {exc}\n")
                kaggle_instructions()
                return 1
            extract(zip_path)

    ainda_faltando = missing_files()
    if ainda_faltando:
        print("\nArquivos ainda ausentes apos a extracao:")
        for name in ainda_faltando:
            print(f"  - {name}")
        return 1

    if not args.skip_validation and not validate():
        return 1

    print("\nPronto. Proximo passo: python src/load_raw.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
