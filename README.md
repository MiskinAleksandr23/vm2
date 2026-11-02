### Cборка
В корне репозитория 
```bash
make -C Lama/runtime
```

Реализовано на **Zig** (https://ziglang.org) \
Язык пока еще разрабатывается, так что нужно использовать последнюю **stable** версию. На текущий момент это **0.17.0** (и должна быть именно такая)

Можно получить разными способами:

**C официального сайта** https://ziglang.org/download/ \
Можно выбрать Linux/x86_64 и **0.17.0**(возможно придется промотать чуть ниже)

В каталоге со скачанным архивом нужно распаковать и можно сделать симлинк
```bash
sudo mkdir -p /opt/zig

sudo tar -xJf zig-x86_64-linux-0.17.0.tar.xz -C /opt/zig

sudo ln -sfn /opt/zig/zig-x86_64-linux-0.17.0/zig /usr/local/bin/zig

zig version   # должно быть 0.17.0
```

**Для новых Ubuntu(25.10 и новее)**
```bash
sudo apt update
sudo apt install zig
zig version    # должно быть 0.17.0
```
Если версия отличается от 0.17.0 то лучше поставить по способу выше.


Далее из корня репозитория. \
Сборка с оптимизациями(при желании можно убрать **-Doptimize=ReleaseFast**)
```
cd lama_vm
zig build -Doptimize=ReleaseFast
```



### Запуск тестов(регрессионные тесты Lama)

```bash
python3 tests/run_lama_regression.py --suite all --no-build --timeout 1200
```

### Бенчмарк(единственный)

```bash
zig build -Doptimize=ReleaseFast
lamac -runtime ../Lama/runtime -b ../Lama/performance/Sort.lama
/usr/bin/time -p ./zig-out/bin/lama_vm Sort.bc < /dev/null

/usr/bin/time -p lamac -s ../Lama/performance/Sort.lama < /dev/null
/usr/bin/time -p lamac -i ../Lama/performance/Sort.lama < /dev/null

lamac -runtime ../Lama/runtime ../Lama/performance/Sort.lama
/usr/bin/time -p ./Sort < /dev/null
```

Локальные результаты(запуск под ARM, так что возможно чуть будет отличаться).

| Вариант | Real, с | User, с | System, с | Пик RAM, МиБ |
|---|---:|---:|---:|---:|
| Нативная Lama (x86_64/Rosetta) | 92,98 | 89,68 | 2,02 | 7,31 |
| `lamac -s` (ARM64) | 136,68 | 119,36 | 11,16 | 4191,98 |
| Наша VM (ReleaseFast, x86_64/Rosetta) | 180,95 | 163,35 | 10,66 | 3737,37 |
| `lamac -i` (ARM64) | 480,46 | 387,59 | 61,67 | 5387,48 |
