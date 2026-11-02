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
| Нативная Lama (рантайм `-O3`, x86_64/Rosetta) | 19,93 | 17,49 | 1,89 | 7,27 |
| `lamac -s` (ARM64) | 132,99 | 117,26 | 9,50 | 4455,08 |
| Наша VM (ReleaseFast, рантайм `-O3`, x86_64/Rosetta) | 63,10 | 56,51 | 5,00 | 6061,54 |
| `lamac -i` (ARM64) | 465,68 | 372,83 | 60,99 | 5451,47 |
