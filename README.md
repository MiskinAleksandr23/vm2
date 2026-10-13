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
TODO
```

### Бенчмарк(единственный)
```bash 
TODO
```

