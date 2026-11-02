import argparse
from collections import Counter
import difflib
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SUITES = {
    "regression": "regression",
    "stdlib": "stdlib/regression",
    "long": "regression_long",
    "performance": "performance",
}


def execute(command, cwd, input_text, timeout):
    try:
        result = subprocess.run(
            command, cwd=cwd, input=input_text, text=True,
            capture_output=True, errors="replace", timeout=timeout,
        )
        return result, None
    except subprocess.TimeoutExpired as error:
        def decode(value):
            return value.decode(errors="replace") if isinstance(value, bytes) else value or ""
        result = subprocess.CompletedProcess(command, -1, decode(error.stdout), decode(error.stderr))
        return result, f"превышен таймаут {timeout:g} с"
    except OSError as error:
        return subprocess.CompletedProcess(command, -1, "", str(error)), "не удалось запустить процесс"


def check_case(source, lama, compiler, vm, timeout, artifacts):
    input_path = source.with_suffix(".input")
    input_text = input_path.read_text(encoding="utf-8", errors="replace") if input_path.exists() else ""
    flags = ["-I", str(lama / "runtime")]
    for directory in (
        source.parent, lama / "_build/default/stdlib/x64",
        lama / "stdlib/x64", lama / "stdlib",
    ):
        if directory.is_dir():
            flags.extend(["-I", str(directory)])

    with tempfile.TemporaryDirectory(prefix="lama-regression-") as folder:
        command = [compiler, *flags, "-b", str(source)]
        result, problem = execute(command, folder, "", timeout)
        if problem or result.returncode != 0:
            reason = f"компиляция: {problem or f'код завершения {result.returncode}'}"
            return "BLOCKED", reason, result, None, None
        code = Path(folder) / source.with_suffix(".bc").name
        if not code.is_file():
            return "BLOCKED", "компилятор не создал .bc", result, None, None

        command = [compiler, *flags, "-s", str(source)]
        reference, problem = execute(command, source.parent, input_text, timeout)
        if problem or reference.returncode != 0:
            reason = f"эталон Lama: {problem or f'код завершения {reference.returncode}'}"
            return "BLOCKED", reason, reference, None, None
        expected = re.sub(r"\A(?: > )+", "", reference.stdout)

        command = [str(vm), str(code)]
        actual, problem = execute(command, source.parent, input_text, timeout)
        actual.stdout = actual.stdout.replace("> ", "")
        if problem or actual.returncode != 0 or actual.stdout != expected:
            saved_code = artifacts / source.relative_to(lama).with_suffix(".bc")
            saved_code.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(code, saved_code)
            actual.args = [str(vm), str(saved_code)]
        if problem or actual.returncode != 0:
            reason = f"VM: {problem or f'код завершения {actual.returncode}'}"
            return "FAIL", reason, actual, expected, actual.stdout
        if actual.stdout != expected:
            return "FAIL", "вывод VM отличается от Lama", actual, expected, actual.stdout
        return "PASS", "", actual, expected, actual.stdout


def main():
    parser = argparse.ArgumentParser(description="Сравнить VM с lamac -s на тестах Lama.")
    parser.add_argument("--suite", choices=["all", *SUITES], default="all")
    parser.add_argument("--lama-dir", type=Path, default=ROOT.parent / "Lama")
    parser.add_argument("--lamac", default="lamac")
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--report", type=Path, default=ROOT / ".zig-cache/lama-regression.log")
    args = parser.parse_args()
    if args.timeout <= 0 or (args.limit is not None and args.limit <= 0):
        parser.error("--timeout и --limit должны быть положительными")

    lama = args.lama_dir.resolve()
    suites = list(SUITES.values()) if args.suite == "all" else [SUITES[args.suite]]
    cases = []
    for suite in suites:
        directory = lama / suite
        if not directory.is_dir():
            parser.error(f"нет каталога тестов: {directory}")
        cases.extend(sorted(directory.rglob("*.lama")))
    if args.limit is not None:
        cases = cases[:args.limit]
    if not cases:
        parser.error("тесты не найдены")
    if args.list:
        print(f"Найдено тестов: {len(cases)}")
        for source in cases:
            print(source)
        return 0

    compiler = shutil.which(args.lamac)
    if compiler is None:
        parser.error(f"компилятор не найден: {args.lamac}")
    vm = ROOT / "zig-out/bin/lama_vm"
    if not args.no_build:
        result, problem = execute(["zig", "build", "-Doptimize=ReleaseSafe"], ROOT, "", args.timeout)
        if problem or result.returncode != 0:
            print(f"Ошибка сборки VM: {problem or result.returncode}")
            print(result.stdout + result.stderr)
            return 1
    if not vm.is_file():
        parser.error(f"VM не найдена: {vm}")

    report = args.report.resolve()
    artifacts = report.parent / (report.stem + "-files")
    report.parent.mkdir(parents=True, exist_ok=True)
    counts = Counter()
    with report.open("w", encoding="utf-8") as log:
        def emit(message):
            print(message, flush=True)
            log.write(message + "\n")
            log.flush()

        emit(f"Тестов: {len(cases)}. Отчёт: {report}")
        for number, source in enumerate(cases, 1):
            status, reason, result, expected, actual = check_case(source, lama, compiler, vm, args.timeout, artifacts)
            counts[status] += 1
            name = source.relative_to(lama)
            if status == "PASS":
                if number % 100 == 0 or number == len(cases):
                    emit(f"[{number}/{len(cases)}] PASS {name}")
                continue

            emit(f"\n[{number}/{len(cases)}] {status} {name}: {reason}")
            emit(f"Файл: {source}")
            input_path = source.with_suffix(".input")
            input_file = shlex.quote(str(input_path)) if input_path.exists() else "/dev/null"
            emit(f"Команда: {shlex.join(result.args)} < {input_file}")
            for line_number, line in enumerate(source.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                emit(f"{line_number:4} | {line}")
            if result.stderr:
                diagnostics = result.stderr
                start = re.search(r"(?m)^(?:error:|Fatal error:|Error:|.*panic:)", diagnostics)
                if start:
                    diagnostics = diagnostics[start.start():]
                emit("Диагностика:\n" + diagnostics.rstrip())
            if expected is not None:
                if actual != expected:
                    diff = "".join(difflib.unified_diff(
                        expected.splitlines(keepends=True), actual.splitlines(keepends=True),
                        fromfile="Lama (-s)", tofile="VM",
                    ))
                    emit("Различия вывода:\n" + diff)
            elif result.stdout:
                emit("Вывод процесса:\n" + result.stdout.rstrip())

        emit(f"\nPASS: {counts['PASS']}, FAIL: {counts['FAIL']}, BLOCKED: {counts['BLOCKED']}")
    return 1 if counts["FAIL"] or counts["BLOCKED"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
