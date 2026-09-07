# Validación independiente del formato público MCL86

Este experimento de Phase 2.80 no es un ensamblador original recuperado ni un
modelo ejecutable de MCL86. Sus herramientas usan únicamente la biblioteca
estándar de Python y no importan el toolchain SPK286. Ningún fichero externo
entra en el manifiesto RTL de la CPU.

## Fuentes y procedencia

`sources.json` fija seis ficheros por URL, commit y SHA-256:

- [MicroCoreLabs/Projects](https://github.com/MicroCoreLabs/Projects/tree/78f3fb0eb230e014f4a53397d8577c3570681b9d/MCL86/Core):
  `Microcode_MCL86.txt` (historial hasta revisión 4, 2/12/2022),
  `MCL86_Microcode_Xilinx_Version_4.coe` y `eu.v`.
- [Reescritura SystemVerilog en PCXT_MiSTer](https://github.com/MiSTer-devel/PCXT_MiSTer/tree/1021f7877b672e21a17e002f2b686ee4e3d3dfe9/rtl/8088):
  `mcl86_ucode.mem`, `mcl86_ucode.sv` y `mcl86_eu_core.sv`.
  Las cabeceras atribuyen el trabajo a Ted Fried y Marcus Andrade;
  el [commit de incorporación](https://github.com/MiSTer-devel/PCXT_MiSTer/commit/1dd8ac50098cfe29239313f7379d111064778a98)
  identifica a Boogermann como coautor. Es la única modificación de esa ruta
  `.mem` en el historial consultado.

Se inspeccionaron las licencias MIT de las cabeceras del fuente original y
del RTL de ambas implementaciones. Los ficheros ROM no añaden una cabecera de
licencia propia. Se conservan como referencias externas en `.cache/mcl86`,
sin redistribuirlos ni reutilizar su contenido en SPK286. El fetch conserva
los bytes originales y rechaza hashes incorrectos; no sobrescribe la caché.

El árbol público de la reescritura, tanto en el commit de incorporación como
en el commit fijado, no contiene `ucasm.py`, `ucdis.py`, `uccheck.py` ni
`docs/learnings.md`, aunque el RTL los menciona. No se afirma que no existan
en otro lugar. No se utilizaron herramientas originales supuestas.

## Formato observado

El TXT es una secuencia de programación, no un lenguaje simbólico de
instrucciones. Se acepta el subconjunto observado, sin expresiones, macros,
símbolos ni inferencia semántica. Tras quitar espacio exterior y comentarios:

```text
p 00 00000 00001 AAAA
p 01 00000 00001 HHHH
p 01 00000 00001 LLLL
```

`AAAA`, `HHHH` y `LLLL` son exactamente cuatro dígitos hexadecimales, sin
prefijo; mayúsculas y minúsculas son equivalentes. Los campos se separan por
un espacio en el formato observado y aceptado. `00` selecciona dirección;
las dos escrituras `01` siguientes entregan primero la mitad alta y después
la baja. `word[31:0] = (HHHH << 16) | LLLL`. No hay autoincremento implícito.
La dirección es de palabra, `0000..0FFF`; el último valor es inclusivo.
El campo fijo `00000` se valida sin atribuirle semántica no documentada.

El destino `00001` selecciona ROM. El destino `00010` tiene un espacio de
control distinto y utiliza el mismo agrupamiento dirección/alta/baja. Sus
transacciones se conservan en el informe, sin escribir en ROM:

| Línea inicial | Dirección de control | Palabra | Comentario original |
| ---: | ---: | ---: | --- |
| 198 | 0001 | 0000000F | Stop CPU |
| 19988 | 0002 | 0000E070 | Set trigger address |
| 19998 | 0001 | 00000000 | Start CPU |

Las directivas `d 20`, `d 1000`, `d 1000` son comandos de demora del transporte;
`x` termina el stream. El archivo no permite demostrar la unidad o base
numérica de esas demoras: se validan como dígitos y conservan como texto opaco.
No producen palabras ni timing de CPU. `x` es opcional para un stream de ROM
canónico; si aparece, cualquier directiva posterior es un error.

`#` y `//` inician comentarios hasta final de línea; se permiten comentarios
completos o tras una directiva. Las líneas vacías y líneas formadas sólo por
guiones son separadores. No se admiten comentarios de bloque, texto libre,
otros destinos ni comandos desconocidos. Las cabeceras descriptivas del
original están comentadas; las líneas de guiones sin comentar son especiales.

Hay 3.299 direcciones de ROM explícitas, sin duplicados, y 797 huecos. Se
rellenan con `00000000`: la coincidencia exhaustiva con la imagen pública v4
demuestra este valor para esta revisión. Los huecos no son instrucciones
implícitamente ensambladas y una palabra cero explícita sigue contando como
dirección asignada. Las direcciones pueden aparecer en cualquier orden; por
ejemplo, la tabla de dispatch se programa al final. Incluso repetir una
dirección con idéntica palabra es un error.

Se rechazan media palabra huérfana, tercera mitad, cambio de destino dentro
de una palabra, dirección nueva o `d`/`x` antes de completarla, fin incompleto,
dirección fuera de rango y fuente sin ninguna escritura ROM. Los diagnósticos
incluyen fichero y línea; los duplicados incluyen la primera línea de origen.

## Campos de microword y ambigüedades

El disassembler conserva los 32 bits, incluidos bits reservados, sin asumir
que todos los patrones sean micro-operaciones ejecutables. Según `eu.v:208`
y `mcl86_eu_core.sv:312`, el RTL decodifica:

| Bits | Uso |
| --- | --- |
| 30:28 | Tipo: 0 NOP, 1 salto, 2 ADD, 3 intercambio de bytes, 4 AND, 5 OR, 6 XOR, 7 desplazamiento |
| 27:24 | Destino en operaciones de datos |
| 23:20 / 19:16 | Selección de operandos |
| 15:0 | Inmediato de datos |
| 24 / 22:20 / 19:16 | CALL, origen y condición del salto |

El texto del fuente dice `Bits[31:28]` para tipo y `Bits[12:0]` junto a
`Immediate[15:0]` para datos. Son discrepancias documentales: el RTL usa
`[30:28]` y `[15:0]`, respectivamente. Los anchos comentados de algunos saltos
calculados tampoco coinciden exactamente con las concatenaciones del RTL.
Nada de esto requiere corregir el TXT ni truncar sus palabras: el empaquetado
por mitades se demuestra contra la ROM. No se intenta validar los saltos ni
certificar la ejecución, los marcadores internos o el timing de MCL86.

La imagen llamada `.coe` contiene realmente 4.096 tokens hexadecimales
separados por espacios, sin cabecera COE ni comas. Se lee como el subconjunto
denso de `$readmemh`, igual que la `.mem` de la reescritura. No se implementa
un lector COE genérico. Se exigen ocho dígitos por palabra y exactamente
4.096 palabras; se rechazan X/Z, direcciones `@`, valores negativos y exceso
de bits. La salida canónica es ASCII, minúsculas, ocho dígitos por línea,
LF y salto final, sin cabecera.

## Resultado reproducible

| Comparación | Resultado |
| --- | --- |
| TXT original ensamblado contra ROM v4 | 4.096/4.096 palabras iguales, 0 diferencias |
| ROM v4 canónica contra salida generada | 36.864/36.864 bytes iguales |
| TXT original contra `.mem` reescrita | 431 palabras diferentes |
| ROM v4 → disassemble → assemble | 4.096/4.096 iguales |
| ROM reescrita → disassemble → assemble | 4.096/4.096 iguales |

Las 431 diferencias son 293 ceros convertidos en palabras no nulas, dos
palabras no nulas convertidas en cero y 136 sustituciones entre palabras no
nulas. Primeras diferencias: `014: 00000000 → 488ffffe`,
`015: 00000000 → 10000f1a`, `016: 00000000 → 4ebfffff`.
También cambia contenido previamente poblado: `1D4: 100002c7 → 100002db`,
`1F6: 10000e12 → 10000e10`, `1F7: 10000e83 → 10000f2b`.

La causa demostrable es que se publican imágenes distintas. El ensamblador
reproduce íntegramente la imagen original; el commit de incorporación entrega
otra imagen con nuevas palabras y destinos distintos. No es un problema de
espacios, endianness o cero de relleno. No hay fuente simbólico público de la
reescritura que permita atribuir con certeza cada una de las 431 diferencias
a una corrección concreta; no se inventa esa historia ni se parchea el original
para forzar una falsa equivalencia. `comparison.json` registra todas ellas.

SHA-256:

| Archivo / representación | SHA-256 |
| --- | --- |
| TXT original, bytes descargados | `5c90aefa77a8b7459b6f9ac20b431368b07d0823f0dcb0b64af6af75bcd43883` |
| ROM v4 `.coe`, bytes descargados | `b3fa073a6046a6a68909e7fba950ad96f0daaf73b4c41cad00b53fc219fa3c54` |
| ROM v4 canónica / generada / reconstruida | `815ae9daea502b70b6fd40d8158db0afad55a7f7eb6e83db309f3c97875631d0` |
| ROM reescrita, bytes descargados | `36331cfced4379edf63e8939478deed4ec1de961f818b5c0bbd3172b01ca7f93` |
| ROM reescrita canónica / reconstruida | `3ed0a2f830a99c70a7877b16a8a771730a650029a0bc1787bc7250b9f007acae` |

La diferencia de hash entre `.coe` original y su representación canónica es
exclusivamente de serialización; la comparación se realiza palabra por palabra
antes de normalizar. Los hashes de los seis originales están en `sources.json`.
La `.mem` reescrita tiene 36.863 bytes y carece de LF final; la representación
canónica añade únicamente ese byte. Sus palabras no cambian.

## Comandos

Desde la raíz del repositorio:

```bash
make mcl86-fetch
make mcl86-test mcl86-check
python3 -m research.mcl86.mcl86_ucasm .cache/mcl86/Microcode_MCL86.txt build/mcl86/generated.mem
python3 -m research.mcl86.mcl86_ucdis .cache/mcl86/mcl86_ucode.mem build/mcl86/canonical.txt
python3 -m research.mcl86.mcl86_ucasm build/mcl86/canonical.txt build/mcl86/reconstructed.mem
cmp build/mcl86/rewrite_mcl86_ucode.mem build/mcl86/reconstructed.mem
```

El fetch es la única operación de red. Los 24 tests sintéticos son offline y
forman parte de `unittest discover -s tests`; incluyen casos negativos del
checker. La comparación pública se exige por separado mediante `mcl86-check`,
en CI y en el gate completo de fase. Una referencia ausente o modificada falla;
no se omite el gate. `SPK286_BUILD_DIR` controla la ubicación de informes en
los targets Make. Las herramientas no ejecutan las directivas de control ni
escriben en hardware. Los nombres de salida de los CLI se proporcionan
explícitamente; sus directorios deben existir.
