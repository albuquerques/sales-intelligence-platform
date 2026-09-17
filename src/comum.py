"""
O que os scripts de src/ têm em comum: a raiz do projeto, o console, o hash dos
arquivos e a conexão com o PostgreSQL.

Cada coisa aqui já esteve copiada em mais de um script, ou era importada de um
script para outro. Um lugar só é um lugar só para corrigir.

SÓ BIBLIOTECA PADRÃO NO TOPO, DE PROPÓSITO. O download_data.py importa este
arquivo e precisa rodar ANTES do `pip install -r requirements.txt`. Por isso o
psycopg é importado dentro de conecta(), a única função que precisa dele.

Os scripts importam daqui com `from comum import ...`, sem ajuste de caminho:
ao rodar `python src/qualquer.py`, o Python põe a pasta do script (src/) no
início da lista de lugares onde procura módulos.
"""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    # Só para o editor conhecer o tipo que conecta() devolve. Quando o programa
    # roda, TYPE_CHECKING é False e este import nunca acontece.
    import psycopg

PROJECT_ROOT = Path(__file__).resolve().parent.parent
ENV_PATH = PROJECT_ROOT / ".env"


def configura_console() -> None:
    """
    Faz o console aceitar acentos. Chamar no topo do script, antes de qualquer
    print.

    O console do Windows usa cp1252 por padrão e quebra ao imprimir caractere
    fora dele. Sem isto, uma mensagem de erro pode virar UnicodeEncodeError e
    esconder o problema real que ela tentava reportar.
    """
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")


def sha256(path: Path) -> str:
    """
    Hash do arquivo lido em blocos de 1 MB, para não carregar 59 MB na memória.

    O make_sample.py grava este hash no manifesto e o download_data.py confere
    contra ele. Uma função só garante que os dois calculam do mesmo jeito.
    """
    h = hashlib.sha256()
    with path.open("rb") as f:
        for bloco in iter(lambda: f.read(1024 * 1024), b""):
            h.update(bloco)
    return h.hexdigest()


def _carrega_env() -> None:
    """
    Le o .env e joga as variaveis no ambiente do processo.

    Escrito a mao em vez de usar python-dotenv: sao 8 linhas e uma dependencia
    a menos num projeto que promete rodar logo apos o clone.

    setdefault (e nao os environ[k] = v) faz variaveis ja presentes no ambiente
    terem precedencia sobre o arquivo -- assim da para sobrescrever a senha em
    um servidor de CI sem editar nada.
    """
    if not ENV_PATH.exists():
        sys.exit(
            f"Arquivo de credenciais nao encontrado: {ENV_PATH}\n"
            f"Crie a partir do modelo:  Copy-Item .env.example .env"
        )
    for linha in ENV_PATH.read_text(encoding="utf-8").splitlines():
        linha = linha.strip()
        if not linha or linha.startswith("#") or "=" not in linha:
            continue
        chave, valor = linha.split("=", 1)
        os.environ.setdefault(chave.strip(), valor.strip())


def conecta() -> psycopg.Connection:
    """
    Le o .env e abre a conexao usando as variaveis PGHOST/PGPORT/PGDATABASE/
    PGUSER/PGPASSWORD, que o psycopg le do ambiente sozinho -- sao os nomes
    padrao da libpq, a mesma biblioteca que o psql usa por baixo.

    STAGING e MART sao o mesmo banco com as mesmas credenciais, por isso a
    conexao mora aqui e nao dentro de um dos dois scripts.

    O erro de conexao e traduzido porque a mensagem crua do PostgreSQL nao
    ajuda quem esta comecando.
    """
    import psycopg

    _carrega_env()
    try:
        return psycopg.connect()
    except psycopg.OperationalError as exc:
        host = os.environ.get("PGHOST", "?")
        port = os.environ.get("PGPORT", "?")
        db = os.environ.get("PGDATABASE", "?")
        sys.exit(
            f"Nao consegui conectar em {host}:{port}/{db}\n"
            f"\n{str(exc).strip()}\n\n"
            f"Verifique:\n"
            f"  1. o servico do PostgreSQL esta rodando?\n"
            f"       Get-Service *postgres*\n"
            f"  2. o banco existe?\n"
            f"       createdb -U postgres {db}\n"
            f"  3. usuario e senha no .env estao corretos?"
        )
