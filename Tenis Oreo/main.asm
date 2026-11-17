; ==========================================================================
; TENNIS STORE (TENIS OREO) - Sistema de Ventas e Inventario
; Lenguajes de Interfaz - Unidad 3, SEGUNDA ETAPA (refactorizacion)
; MASM x86 (32 bits) + Irvine32
; Equipo: Leonardo David Garcia Leyva
;         Jesus Armando Gastelum Medina
;         Jose Esteban Villalva Felix
;
; Que cambia en esta version (el comportamiento NO cambia):
;  * Macros       : secuencias cortas y repetidas (ver seccion MACROS).
;  * Procedimientos nuevos: AskName, AskPrice, AskCount, StoreProduct,
;                   CalcSale, CommitSale, ShowSale (se separan tareas que
;                   antes estaban mezcladas dentro de otros procedimientos).
;  * USES         : sustituye a los PUSH/POP manuales y a PUSHAD/POPAD.
;                   Cada lista contiene SOLO los registros que el
;                   procedimiento altera y cuyo valor debe conservarse.
;                   Los registros que devuelven resultado (EAX, ESI, EDI,
;                   ECX segun el caso) NO se incluyen en USES.
;  * Se elimina AskQty (la reemplaza AskCount + macro ASKQTY) y ShowHeader
;    (la reemplaza la macro SHOWHEADER).
;
; Notas generales (heredadas de la primera etapa)
;  * Entrada: SOLO ReadString. Salida de numeros: SOLO WriteString.
;    No se usa ReadDec, ReadInt, ParseDecimal32, WriteDec ni WriteHex.
;  * Precios en centavos enteros (DWORD). Se muestran como pesos.cc MXN.
;  * Registro de producto = 44 bytes (ver estructura abajo). Se recorre con ESI.
;  * Archivo de TEXTO (.txt): 1a linea "TNS1"; despues una linea por producto
;      CODIGO;NOMBRE;PRECIO;EXISTENCIA     ej.  NIK-001;Nike Air Max;1899.99;15
;    El texto se convierte a una imagen binaria temporal (parseImg) que se
;    valida completa ANTES de reemplazar el catalogo. (SIN CAMBIOS: los
;    archivos .txt generados por la version anterior se leen igual.)
;  * Textos sin acentos para evitar problemas con la pagina de codigos de
;    la consola de Windows.
;  * Convencion de documentacion de cada procedimiento:
;       ENTRADA / SALIDA / MODIFICA / CONSERVA / USES (por que) / PILA
;    Con USES el ensamblador inserta PUSH al entrar y los POP inversos antes
;    de CADA RET; los POP no alteran las banderas, por eso los procedimientos
;    que devuelven CF siguen funcionando.
; ==========================================================================
INCLUDE Irvine32.inc

; ---------------------------------------------------------------- constantes
MAXPROD     EQU 10                      ; maximo de productos
MAXSTOCK    EQU 100                     ; existencia maxima por producto
MAXNAME     EQU 25                      ; caracteres maximos del nombre
MAXPRICE    EQU 999999                  ; $9999.99 en centavos
RECSIZE     EQU 44                      ; tamano de un registro
OFS_CODE    EQU 0                       ; 8 bytes  : "ABC-123",0
OFS_NAME    EQU 8                       ; 28 bytes : nombre + 0 + relleno
OFS_PRICE   EQU 36                      ; DWORD    : precio en centavos
OFS_STOCK   EQU 40                      ; DWORD    : existencia
HDRSIZE     EQU 8                       ; "TNS1" + cantidad
LOADCAP     EQU 1024                    ; capacidad del buffer de texto (lectura y escritura)
INMAX       EQU 40                      ; maximo de caracteres leidos por ReadString
DISC_MIN    EQU 3                       ; regla: pares minimos para descuento
DISC_PCT    EQU 10                      ; regla: porcentaje de descuento
DEFCOUNT    EQU 5                       ; productos iniciales
DEFLEN      EQU HDRSIZE + DEFCOUNT*RECSIZE
MAGIC       EQU 31534E54h               ; "TNS1" en little-endian (54h 4Eh 53h 31h)

; ==========================================================================
; ------------------------------  MACROS  ----------------------------------
; Las macros ahorran escritura en el archivo FUENTE; MASM las expande en cada
; punto de uso, por lo que el codigo maquina generado no se reduce.
; ==========================================================================

; --------------------------------------------------------------------------
; SAY - muestra una cadena terminada en 0
; Parametros : txt = etiqueta de la cadena
; Sustituye  : push edx / mov edx,OFFSET txt / call WriteString / pop edx
; Usada en   : todo el programa (mensajes de error, avisos y etiquetas)
; Conserva   : todos los registros
; --------------------------------------------------------------------------
SAY MACRO txt
    push edx
    mov  edx, OFFSET txt
    call WriteString
    pop  edx
ENDM

; --------------------------------------------------------------------------
; FAILTO - muestra un mensaje de error y salta a la etiqueta de salida
; Parametros : msg = cadena de error ; target = etiqueta de destino
; Sustituye  : SAY msg / jmp target
; Usada en   : RegisterProduct, SellProduct, LoadInventory
; --------------------------------------------------------------------------
FAILTO MACRO msg, target
    SAY  msg
    jmp  target
ENDM

; --------------------------------------------------------------------------
; SAYUINT - etiqueta + entero sin signo + salto de linea
; Parametros : txt = etiqueta ; valOp = registro, variable o [memoria] con el valor
; Sustituye  : SAY txt / mov eax,valOp / call PrintUInt / call Crlf
; Usada en   : InitCatalog, ReceiveStock, SellProduct, ShowSale, ShowSummary,
;              SaveInventory, LoadInventory
; Modifica   : EAX
; --------------------------------------------------------------------------
SAYUINT MACRO txt, valOp
    SAY  txt
    mov  eax, valOp
    call PrintUInt
    call Crlf
ENDM

; --------------------------------------------------------------------------
; SAYMXN - etiqueta + importe en centavos mostrado como "pesos.cc MXN" + CRLF
; Parametros : txt = etiqueta ; valOp = registro, variable o [memoria] en centavos
; Sustituye  : SAY txt / mov eax,valOp / call PrintMXN / call Crlf
; Usada en   : ShowSale, ShowSummary
; Modifica   : EAX
; --------------------------------------------------------------------------
SAYMXN MACRO txt, valOp
    SAY  txt
    mov  eax, valOp
    call PrintMXN
    call Crlf
ENDM

; --------------------------------------------------------------------------
; SHOWHEADER - encabezado de la tabla de productos
; Parametros : ninguno
; Sustituye  : el antiguo procedimiento ShowHeader (una sola instruccion util)
; Usada en   : ListInventory, SearchProduct, SellProduct
; --------------------------------------------------------------------------
SHOWHEADER MACRO
    SAY  msgHeader
ENDM

; --------------------------------------------------------------------------
; PREPINPUT - prepara los registros de ReadString sobre inBuf
; Parametros : ninguno
; Sustituye  : mov edx,OFFSET inBuf / mov ecx,INMAX
; Usada en   : ReadLine (lectura inicial y vaciado de linea larga)
; Modifica   : EDX, ECX
; --------------------------------------------------------------------------
PREPINPUT MACRO
    mov  edx, OFFSET inBuf              ; EDX = donde guardar la entrada
    mov  ecx, INMAX                     ; ECX = maximo de caracteres
ENDM

; --------------------------------------------------------------------------
; CLEARMEM - llena de ceros un bloque de memoria con REP STOSB
; Parametros : dstBuf = etiqueta del bloque ; nBytes = cantidad de bytes
; Sustituye  : mov edi,OFFSET dstBuf / mov ecx,nBytes / xor al,al / rep stosb
; Usada en   : InstallImage (catalogo), ParseText (imagen temporal)
; Modifica   : EDI, ECX, AL
; --------------------------------------------------------------------------
CLEARMEM MACRO dstBuf, nBytes
    mov  edi, OFFSET dstBuf
    mov  ecx, nBytes
    xor  al, al
    rep  stosb
ENDM

; --------------------------------------------------------------------------
; PUTCH - escribe un caracter en [EDI] y avanza EDI
; Parametros : theChar = caracter literal o registro de 8 bits (AL, DL)
; Sustituye  : mov BYTE PTR [edi],theChar / inc edi
; Usada en   : FormatMXN ('.', decenas y unidades), BuildText (';' x3)
; Modifica   : EDI
; --------------------------------------------------------------------------
PUTCH MACRO theChar
    mov  BYTE PTR [edi], theChar
    inc  edi
ENDM

; --------------------------------------------------------------------------
; DIGITCHK - convierte un caracter ASCII a 0..9 y salta si no era digito
; Parametros : reg8 = registro de 8 bits con el caracter ; badLbl = destino
; Sustituye  : sub reg8,'0' / cmp reg8,9 / ja badLbl
; Usada en   : ParseUInt (1 vez), ParsePrice (3 veces)
; Modifica   : reg8, EFLAGS
; --------------------------------------------------------------------------
DIGITCHK MACRO reg8, badLbl
    sub  reg8, '0'                      ; ASCII -> valor 0..9
    cmp  reg8, 9
    ja   badLbl                         ; no era digito
ENDM

; --------------------------------------------------------------------------
; PADFIELD - imprime un campo de texto del registro (ESI) con ancho fijo
; Parametros : fieldOfs = desplazamiento OFS_* ; colWid = ancho de columna
; Sustituye  : lea edx,[esi+fieldOfs] / mov ecx,colWid / call PrintPadded
; Usada en   : ShowRecord (codigo y nombre)
; Modifica   : EDX, ECX
; --------------------------------------------------------------------------
PADFIELD MACRO fieldOfs, colWid
    lea  edx, [esi+fieldOfs]
    mov  ecx, colWid
    call PrintPadded
ENDM

; --------------------------------------------------------------------------
; STASHSTR - copia la cadena apuntada por EDX a una variable temporal
; Parametros : dstVar = etiqueta de la variable destino (tmpCode, tmpName)
; Sustituye  : mov esi,edx / mov edi,OFFSET dstVar / call CopyStr
; Usada en   : RegisterProduct (codigo y nombre)
; Modifica   : ESI, EDI
; --------------------------------------------------------------------------
STASHSTR MACRO dstVar
    mov  esi, edx
    mov  edi, OFFSET dstVar
    call CopyStr
ENDM

; --------------------------------------------------------------------------
; ASKQTY / ASKSTOCK - piden un entero con AskCount (mismo codigo, distinto
;                     minimo y distinto mensaje de error)
; Parametros : pmsg = cadena del mensaje de captura
; ASKQTY   sustituye: mov edx,OFFSET pmsg / mov ecx,1 / mov ebx,OFFSET msgBadQty   / call AskCount
; ASKSTOCK sustituye: mov edx,OFFSET pmsg / mov ecx,0 / mov ebx,OFFSET msgBadStock / call AskCount
; Usadas en  : ASKQTY (ReceiveStock, SellProduct), ASKSTOCK (RegisterProduct)
; Modifican  : EDX, ECX, EBX, EAX (resultado), CF
; --------------------------------------------------------------------------
ASKQTY MACRO pmsg
    mov  edx, OFFSET pmsg
    mov  ecx, 1
    mov  ebx, OFFSET msgBadQty
    call AskCount
ENDM

ASKSTOCK MACRO pmsg
    mov  edx, OFFSET pmsg
    mov  ecx, 0
    mov  ebx, OFFSET msgBadStock
    call AskCount
ENDM

; --------------------------------------------------------------------------
; ASKVALID - cuerpo comun de AskCode, AskName y AskPrice: lee una linea no
;            vacia, la pasa por un validador y muestra el error si falla
; Parametros : validator = procedimiento (ENTRADA EDX->cadena, SALIDA CF)
;              errMsg    = cadena del error de validacion
; Sustituye  : call AskLine / jc fin / call validator / jnc fin / SAY errMsg / stc
; Usada en   : AskCode, AskName, AskPrice
; LOCAL      : "done" (cada expansion necesita su propia etiqueta de salida)
; --------------------------------------------------------------------------
ASKVALID MACRO validator, errMsg
    LOCAL done
    call AskLine
    jc   done                           ; error de AskLine ya mostrado (CF=1)
    call validator
    jnc  done                           ; valido (CF=0)
    SAY  errMsg
    stc
done:
ENDM

; --------------------------------------------------------------------------
; MENUOPT - una rama del menu: si AL coincide con la tecla, llama al
;           procedimiento y vuelve a la verificacion de registros de main
; Parametros : key = caracter de la opcion ; handler = procedimiento a llamar
; Sustituye  : cmp al,key / jne siguiente / call handler / jmp m_after
; Usada en   : main (opciones 1 a 8)
; LOCAL      : "skip" (se usa 8 veces dentro de main)
; --------------------------------------------------------------------------
MENUOPT MACRO key, handler
    LOCAL skip
    cmp  al, key
    jne  skip
    call handler
    jmp  m_after
skip:
ENDM

.data
; ---- Catalogo en memoria (registros de 44 bytes) ---------------------------
fileMagic   BYTE "TNS1"                 ; marca del formato (el archivo de texto la repite en su 1a linea)
prodCount   DWORD 0                     ; cantidad de productos
catalog     BYTE MAXPROD*RECSIZE DUP(0) ; registros de 44 bytes

; ---- Estado de la sesion --------------------------------------------------
income      DWORD 0                     ; ingresos de la sesion (centavos)
dirty       BYTE 0                      ; 1 = hay cambios sin guardar
curRec      DWORD 0                     ; registro seleccionado (puntero)
espRef      DWORD 0                     ; ESP de referencia (verificacion de pila)

; ---- Constantes de calculo (para DIV/MUL con memoria) ---------------------
cien        DWORD 100
pct         DWORD DISC_PCT

; ---- Buffers --------------------------------------------------------------
inBuf       BYTE INMAX+1 DUP(0)         ; entrada de ReadString (+1 para el 00h)
outBuf      BYTE 40 DUP(0)              ; cadena numerica de salida
tmpCode     BYTE 8 DUP(0)               ; alta en preparacion
tmpName     BYTE 28 DUP(0)
tmpPrice    DWORD 0
tmpStock    DWORD 0
fileBuf     BYTE INMAX+1 DUP(0)         ; nombre de archivo elegido
defFile     BYTE "inventario.txt",0
fileHandle  DWORD 0
bytesWanted DWORD 0
bytesRead   DWORD 0
bytesWritten DWORD 0
; capacidad = LOADCAP; se reserva 1 byte extra para el terminador 00h
loadBuf     BYTE LOADCAP+1 DUP(0)
saveBuf     BYTE LOADCAP+1 DUP(0)       ; texto que se escribe en el archivo
; imagen binaria temporal construida a partir del texto (misma estructura que defImage)
parseImg    BYTE "TNS1"
parseCnt    DWORD 0
parseRecs   BYTE MAXPROD*RECSIZE DUP(0)

; ---- Catalogo inicial (misma estructura que el archivo) -------------------
defImage    BYTE "TNS1"
            DWORD DEFCOUNT
            ; NIK-001
            BYTE "NIK-001",0
            BYTE "Nike Air Max",0
            BYTE 15 DUP(0)
            DWORD 189999, 15
            ; ADI-002
            BYTE "ADI-002",0
            BYTE "Adidas Superstar",0
            BYTE 11 DUP(0)
            DWORD 159950, 12
            ; PUM-003
            BYTE "PUM-003",0
            BYTE "Puma RS-X",0
            BYTE 18 DUP(0)
            DWORD 179900, 10
            ; CON-004
            BYTE "CON-004",0
            BYTE "Converse Chuck Taylor",0
            BYTE 6 DUP(0)
            DWORD 119999, 20
            ; NBW-005
            BYTE "NBW-005",0
            BYTE "New Balance 574",0
            BYTE 12 DUP(0)
            DWORD 219950, 8

; ---- Mensajes -------------------------------------------------------------
msgBanner   BYTE 0Dh,0Ah,"=== TENIS OREO REDUX - Sistema de Ventas e Inventario ===",0Dh,0Ah,0
msgMenu     BYTE 0Dh,0Ah
            BYTE "1. Registrar producto",0Dh,0Ah
            BYTE "2. Consultar inventario",0Dh,0Ah
            BYTE "3. Buscar por codigo",0Dh,0Ah
            BYTE "4. Recibir mercancia",0Dh,0Ah
            BYTE "5. Vender",0Dh,0Ah
            BYTE "6. Resumen",0Dh,0Ah
            BYTE "7. Guardar inventario",0Dh,0Ah
            BYTE "8. Cargar inventario",0Dh,0Ah
            BYTE "9. Ver regla del negocio",0Dh,0Ah
            BYTE "0. Salir",0Dh,0Ah,0
pOpt        BYTE "Opcion: ",0
msgBadOpt   BYTE "Opcion no valida.",0Dh,0Ah,0
msgHeader   BYTE "Codigo    Nombre                     Precio          Existencia",0Dh,0Ah
            BYTE "-------------------------------------------------------------------",0Dh,0Ah,0
msgNoProd   BYTE "El inventario esta vacio.",0Dh,0Ah,0
msgEmpty    BYTE "Error: la entrada esta vacia.",0Dh,0Ah,0
msgTooLong  BYTE "Error: la entrada es demasiado larga.",0Dh,0Ah,0
msgBadCode  BYTE "Error: codigo invalido (formato ABC-123: 3 letras mayusculas, guion, 3 digitos).",0Dh,0Ah,0
msgBadName  BYTE "Error: nombre invalido (1 a 25 caracteres imprimibles, sin punto y coma).",0Dh,0Ah,0
msgBadPrice BYTE "Error: precio invalido (0.01 a 9999.99; enteros o 1-2 decimales; sin simbolos ni comas).",0Dh,0Ah,0
msgBadStock BYTE "Error: existencia invalida (entero de 0 a 100).",0Dh,0Ah,0
msgBadQty   BYTE "Error: cantidad invalida (solo digitos, entero de 1 a 100).",0Dh,0Ah,0
msgBadFile  BYTE "Error: nombre de archivo demasiado largo.",0Dh,0Ah,0
msgFull     BYTE "Error: el catalogo esta lleno (maximo 10 productos).",0Dh,0Ah,0
msgDup      BYTE "Error: ya existe un producto con ese codigo. No se hizo ningun cambio.",0Dh,0Ah,0
msgNotFound BYTE "No existe un producto con ese codigo.",0Dh,0Ah,0
msgAdded    BYTE "Producto registrado correctamente.",0Dh,0Ah,0
pCode       BYTE "Codigo (ABC-123): ",0
pName       BYTE "Nombre (1-25 caracteres): ",0
pPrice      BYTE "Precio en MXN (ej. 1899.99): ",0
pStock      BYTE "Existencia inicial (0-100): ",0
pCodeSrch   BYTE "Codigo a buscar: ",0
pCodeRecv   BYTE "Codigo del producto que recibe mercancia: ",0
pQtyRecv    BYTE "Unidades recibidas (1-100): ",0
pCodeSell   BYTE "Codigo del producto a vender: ",0
pQtySell    BYTE "Cantidad de pares a vender (1-100): ",0
msgRecvOK   BYTE "Mercancia recibida. Nueva existencia: ",0
msgRecvOver BYTE "Error: la existencia superaria 100 unidades. Existencia actual: ",0
msgNoStock  BYTE "Venta rechazada: existencia insuficiente. Disponible: ",0
msgOvf      BYTE "Error: desbordamiento en el calculo. Operacion cancelada sin cambios.",0Dh,0Ah,0
msgSold     BYTE "Venta aceptada.",0Dh,0Ah,0
msgBase     BYTE "  Importe base : ",0
msgDisc     BYTE "  Descuento    : ",0
msgDiscYes  BYTE "  (10% por comprar 3 o mas pares)",0
msgDiscNo   BYTE "  (sin descuento: menos de 3 pares)",0
msgFinal    BYTE "  Importe final: ",0
msgLeft     BYTE "  Existencia restante: ",0
msgSumTitle BYTE 0Dh,0Ah,"--- Resumen de la sesion ---",0Dh,0Ah,0
msgSumProd  BYTE "Productos registrados   : ",0
msgSumUnits BYTE "Unidades disponibles    : ",0
msgSumValue BYTE "Valor total del inventario: ",0
msgSumInc   BYTE "Ingresos de la sesion   : ",0
msgRule     BYTE 0Dh,0Ah
            BYTE "--- Regla del negocio: descuento por compra de varios pares ---",0Dh,0Ah
            BYTE "Se aplica cuando una venta incluye 3 o mas pares del mismo modelo.",0Dh,0Ah
            BYTE "Descuento = 10% del importe base; la fraccion de centavo se descarta.",0Dh,0Ah
            BYTE "Con 1 o 2 pares NO se aplica descuento.",0Dh,0Ah,0
pFile       BYTE "Archivo (Enter = inventario.txt): ",0
msgSaveOK   BYTE "Inventario guardado. Bytes escritos: ",0
msgSaveErr  BYTE "Error: no se pudo crear o escribir el archivo completo.",0Dh,0Ah,0
msgLoadOK   BYTE "Inventario cargado. Productos recuperados: ",0
msgLoadNo   BYTE "Error: el archivo no existe.",0Dh,0Ah,0
msgLoadRd   BYTE "Error: no se pudo leer el archivo.",0Dh,0Ah,0
msgLoadBad  BYTE "Error: archivo invalido o danado. El catalogo actual no se modifico.",0Dh,0Ah,0
msgStartDef BYTE "Inicio con los 5 productos de prueba (no se encontro un inventario valido).",0Dh,0Ah,0
msgStartOK  BYTE "Se recupero inventario.txt al iniciar. Productos: ",0
msgWarnLoad BYTE "Aviso: hay cambios sin guardar que se perderan al cargar.",0Dh,0Ah,0
pContinue   BYTE "Continuar? (S/N): ",0
msgUnsaved  BYTE "Aviso: hay cambios sin guardar.",0Dh,0Ah,0
pExit       BYTE "S = salir sin guardar, G = guardar y salir, otra tecla = cancelar: ",0
msgStackErr BYTE "[DIAGNOSTICO] La pila quedo desequilibrada.",0Dh,0Ah,0
msgRegErr   BYTE "[DIAGNOSTICO] Un procedimiento no conservo EBX/ESI/EDI.",0Dh,0Ah,0
msgBye      BYTE "Hasta luego.",0Dh,0Ah,0

.code
; ==========================================================================
; main - inicia el catalogo, ejecuta el menu repetitivo y verifica pila/registros
; (main no es llamado por nadie: no lleva USES; las opciones 1-8 usan MENUOPT)
; ==========================================================================
main PROC
    cld
    mov  espRef, esp                    ; referencia para comprobar la pila
    call InitCatalog
    SAY  msgBanner

menu_loop:
    cmp  esp, espRef                    ; la pila debe estar igual en cada vuelta
    je   m_stackOK
    SAY  msgStackErr
m_stackOK:
    SAY  msgMenu
    mov  edx, OFFSET pOpt
    call AskLine                        ; EAX = longitud, EDX -> inBuf
    jc   menu_loop
    cmp  eax, 1
    jne  m_bad
    mov  al, [edx]
    mov  ebx, 0A1B2C3D4h                ; valores centinela para probar que
    mov  esi, 11112222h                 ; los procedimientos conservan
    mov  edi, 33334444h                 ; EBX, ESI y EDI
    MENUOPT '1', RegisterProduct
    MENUOPT '2', ListInventory
    MENUOPT '3', SearchProduct
    MENUOPT '4', ReceiveStock
    MENUOPT '5', SellProduct
    MENUOPT '6', ShowSummary
    MENUOPT '7', SaveInventory
    MENUOPT '8', LoadInventory
    cmp  al, '9'
    jne  m0
    SAY  msgRule
    jmp  m_after
m0: cmp  al, '0'
    jne  m_bad
    call ConfirmExit                    ; EAX = 1 salir, 0 permanecer
    test eax, eax
    jz   menu_loop
    SAY  msgBye
    exit

m_bad:
    SAY  msgBadOpt
    jmp  menu_loop

m_after:                                ; verificacion de registros conservados
    cmp  ebx, 0A1B2C3D4h
    jne  m_regErr
    cmp  esi, 11112222h
    jne  m_regErr
    cmp  edi, 33334444h
    je   menu_loop
m_regErr:
    SAY  msgRegErr
    jmp  menu_loop
main ENDP

; ==========================================================================
; ----------------------  ENTRADA Y VALIDACION  ----------------------------
; ==========================================================================

; --------------------------------------------------------------------------
; ReadLine - captura una linea con ReadString (EDX=buffer, ECX=maximo)
; ENTRADA : ninguna
; SALIDA  : EAX = caracteres leidos (EAX = INMAX si hubo exceso)
;           EDX -> inBuf (cadena terminada en 0 por ReadString)
;           CF = 1 si la linea lleno el buffer (demasiado larga; se vacia)
; MODIFICA: EAX, EDX, EFLAGS
; CONSERVA: ECX (USES)
; USES    : ECX se usa como maximo para ReadString y el llamador no espera
;           que cambie. EAX y EDX son resultados, por eso NO van en USES.
; PILA    : equilibrada; USES inserta PUSH ECX / POP ECX en cada RET
; --------------------------------------------------------------------------
ReadLine PROC USES ecx
    PREPINPUT
    call ReadString                     ; EAX = caracteres capturados
    cmp  eax, INMAX
    jb   rl_ok
rl_flush:                               ; linea demasiado larga: vaciar el resto
    PREPINPUT
    call ReadString
    cmp  eax, INMAX
    jae  rl_flush
    mov  eax, INMAX
    mov  edx, OFFSET inBuf
    stc
    ret
rl_ok:
    mov  edx, OFFSET inBuf
    clc
    ret
ReadLine ENDP

; --------------------------------------------------------------------------
; AskLine - muestra un mensaje y lee una linea no vacia
; ENTRADA : EDX -> mensaje (cadena terminada en 0)
; SALIDA  : EAX = longitud, EDX -> inBuf ; CF = 1 si vacia o demasiado larga
;           (el error ya fue mostrado)
; MODIFICA: EAX, EDX, EFLAGS (ambos registros son resultado)
; CONSERVA: los demas
; USES    : no lleva; todo lo que altera es resultado
; --------------------------------------------------------------------------
AskLine PROC
    call WriteString
    call ReadLine
    jc   al_long
    test eax, eax
    jz   al_empty
    clc
    ret
al_long:
    SAY  msgTooLong
    stc
    ret
al_empty:
    SAY  msgEmpty
    stc
    ret
AskLine ENDP

; --------------------------------------------------------------------------
; AskCode - pide y valida un codigo ABC-123 (usa ASKVALID + ValidateCode)
; ENTRADA : EDX -> mensaje
; SALIDA  : EDX -> inBuf con el codigo ; CF = 1 si es invalido
; MODIFICA: EAX, EDX, EFLAGS
; USES    : no lleva; ValidateCode ya conserva sus registros
; --------------------------------------------------------------------------
AskCode PROC
    ASKVALID ValidateCode, msgBadCode
    ret
AskCode ENDP

; --------------------------------------------------------------------------
; AskName - NUEVO. Pide y valida un nombre de producto (usa ASKVALID)
; ENTRADA : EDX -> mensaje
; SALIDA  : EDX -> inBuf con el nombre ; CF = 1 si es invalido
; MODIFICA: EAX, EDX, EFLAGS
; USES    : no lleva; mismo esquema que AskCode
; --------------------------------------------------------------------------
AskName PROC
    ASKVALID ValidateName, msgBadName
    ret
AskName ENDP

; --------------------------------------------------------------------------
; AskPrice - NUEVO. Pide un precio y lo convierte a centavos (usa ASKVALID)
; ENTRADA : EDX -> mensaje
; SALIDA  : EAX = centavos ; EDX -> inBuf ; CF = 1 si es invalido
; MODIFICA: EAX, EDX, EFLAGS
; USES    : no lleva; EAX es el valor devuelto por ParsePrice y NO debe
;           restaurarse
; --------------------------------------------------------------------------
AskPrice PROC
    ASKVALID ParsePrice, msgBadPrice
    ret
AskPrice ENDP

; --------------------------------------------------------------------------
; AskCount - NUEVO. Pide un entero entre un minimo y MAXSTOCK (solo digitos).
;            Reemplaza a AskQty y a la captura de existencia de RegisterProduct.
; ENTRADA : EDX -> mensaje ; ECX = minimo permitido (0 o 1)
;           EBX -> cadena de error para un valor fuera de rango (ver ASKQTY/ASKSTOCK)
; SALIDA  : EAX = valor ; CF = 1 si es invalido (error ya mostrado)
; MODIFICA: EAX, EDX, EFLAGS
; CONSERVA: EBX, ECX (USES)
; USES    : EBX y ECX llegan como parametros y se pueden alterar dentro
;           (ParseUInt, comparaciones); el llamador no los espera cambiados.
;           EAX y EDX son resultado y quedan fuera.
; PILA    : equilibrada (PUSH EBX, ECX al entrar; POP en cada RET)
; --------------------------------------------------------------------------
AskCount PROC USES ebx ecx
    call AskLine
    jc   ak_end                         ; error de AskLine ya mostrado
    call ParseUInt
    jc   ak_bad
    cmp  eax, ecx                       ; minimo
    jb   ak_bad
    cmp  eax, MAXSTOCK                  ; maximo
    ja   ak_bad
    clc
    ret
ak_bad:
    mov  edx, ebx                       ; mensaje de error del llamador
    call WriteString
    stc
ak_end:
    ret
AskCount ENDP

; --------------------------------------------------------------------------
; ValidateCode - formato exacto: 3 letras A-Z, '-', 3 digitos, fin de cadena
; ENTRADA : EDX -> cadena
; SALIDA  : CF = 0 valido, CF = 1 invalido
; MODIFICA: EFLAGS
; CONSERVA: EAX, ECX, ESI, EDX (USES: AL, ECX y ESI se alteran como trabajo)
; PILA    : equilibrada
; --------------------------------------------------------------------------
ValidateCode PROC USES eax ecx esi
    mov  esi, edx
    mov  ecx, 3
vc_let:
    mov  al, [esi]
    cmp  al, 'A'
    jb   vc_bad
    cmp  al, 'Z'
    ja   vc_bad
    inc  esi
    loop vc_let
    cmp  BYTE PTR [esi], '-'
    jne  vc_bad
    inc  esi
    mov  ecx, 3
vc_dig:
    mov  al, [esi]
    cmp  al, '0'
    jb   vc_bad
    cmp  al, '9'
    ja   vc_bad
    inc  esi
    loop vc_dig
    cmp  BYTE PTR [esi], 0              ; no debe haber mas caracteres
    jne  vc_bad
    clc
    ret
vc_bad:
    stc
    ret
ValidateCode ENDP

; --------------------------------------------------------------------------
; ValidateName - 1 a 25 caracteres imprimibles (32..126), sin ";" (separador del archivo)
; ENTRADA : EDX -> cadena terminada en 0
; SALIDA  : CF = 0 valido, CF = 1 invalido
; MODIFICA: EFLAGS
; CONSERVA: EAX, ECX, ESI, EDX (USES: se usan como AL, longitud y puntero)
; PILA    : equilibrada
; --------------------------------------------------------------------------
ValidateName PROC USES eax ecx esi
    mov  esi, edx
    xor  ecx, ecx                       ; ECX = longitud
vn_loop:
    mov  al, [esi]
    test al, al
    jz   vn_end
    cmp  al, 32
    jb   vn_bad
    cmp  al, 126
    ja   vn_bad
    cmp  al, ';'
    je   vn_bad                         ; el ; separa campos en el archivo
    inc  ecx
    cmp  ecx, MAXNAME
    ja   vn_bad                         ; mas de 25 caracteres
    inc  esi
    jmp  vn_loop
vn_end:
    test ecx, ecx                       ; vacio no es valido
    jz   vn_bad
    clc
    ret
vn_bad:
    stc
    ret
ValidateName ENDP

; --------------------------------------------------------------------------
; ParseUInt - convierte una cadena de digitos a entero (conversion propia)
;             valor = valor*10 + (caracter - '0'), sin ReadDec/ParseDecimal32
; ENTRADA : EDX -> cadena terminada en 0
; SALIDA  : EAX = valor ; CF = 1 si esta vacia, tiene un caracter que no es
;           digito o supera 999999 (evita desbordamiento)
; MODIFICA: EAX, EFLAGS
; CONSERVA: EBX, ECX, ESI, EDX (USES: EBX=digito actual, ECX=contador, ESI=puntero)
;           EAX queda fuera de USES porque es el valor devuelto
; PILA    : equilibrada
; --------------------------------------------------------------------------
ParseUInt PROC USES ebx ecx esi
    mov  esi, edx
    xor  eax, eax
    xor  ecx, ecx                       ; ECX = cantidad de digitos
pu_loop:
    movzx ebx, BYTE PTR [esi]
    test bl, bl
    jz   pu_end
    DIGITCHK bl, pu_bad
    imul eax, eax, 10
    add  eax, ebx
    cmp  eax, 999999
    ja   pu_bad
    inc  ecx
    inc  esi
    jmp  pu_loop
pu_end:
    test ecx, ecx
    jz   pu_bad
    clc
    ret
pu_bad:
    xor  eax, eax
    stc
    ret
ParseUInt ENDP

; --------------------------------------------------------------------------
; ParsePrice - convierte "185.50" / "12.05" / "300" a centavos enteros
;   pesos*100 + decimales. Acepta enteros o punto con 1 o 2 decimales.
;   Rechaza: vacio, simbolos, comas, punto sin digitos antes o despues,
;   tercer decimal y valores fuera de 0.01 - 9999.99.
; ENTRADA : EDX -> cadena terminada en 0
; SALIDA  : EAX = centavos ; CF = 1 si es invalido
; MODIFICA: EAX, EFLAGS
; CONSERVA: EBX, ECX, ESI, EDX (USES); EAX fuera de USES (valor devuelto)
; PILA    : equilibrada
; --------------------------------------------------------------------------
ParsePrice PROC USES ebx ecx esi
    mov  esi, edx
    xor  eax, eax                       ; EAX = pesos
    xor  ecx, ecx                       ; ECX = digitos enteros
pp_int:
    movzx ebx, BYTE PTR [esi]
    test bl, bl
    jz   pp_nodot
    cmp  bl, '.'
    je   pp_dot
    DIGITCHK bl, pp_bad
    imul eax, eax, 10
    add  eax, ebx
    cmp  eax, 9999                      ; evita desbordar y valida el limite
    ja   pp_bad
    inc  ecx
    inc  esi
    jmp  pp_int
pp_nodot:                               ; solo pesos enteros
    test ecx, ecx
    jz   pp_bad
    imul eax, eax, 100                  ; pesos -> centavos
    jmp  pp_range
pp_dot:
    test ecx, ecx                       ; debe haber digitos antes del punto
    jz   pp_bad
    imul eax, eax, 100
    inc  esi                            ; saltar el punto
    movzx ebx, BYTE PTR [esi]           ; primer decimal (obligatorio)
    test bl, bl
    jz   pp_bad
    DIGITCHK bl, pp_bad
    imul ebx, ebx, 10                   ; decenas de centavo
    add  eax, ebx
    inc  esi
    movzx ebx, BYTE PTR [esi]           ; segundo decimal (opcional)
    test bl, bl
    jz   pp_range
    DIGITCHK bl, pp_bad
    add  eax, ebx                       ; unidades de centavo
    inc  esi
    cmp  BYTE PTR [esi], 0              ; un tercer decimal se rechaza
    jne  pp_bad
pp_range:
    cmp  eax, 1
    jb   pp_bad
    cmp  eax, MAXPRICE
    ja   pp_bad
    clc
    ret
pp_bad:
    xor  eax, eax
    stc
    ret
ParsePrice ENDP

; ==========================================================================
; ----------------------  CONVERSION Y SALIDA  -----------------------------
; ==========================================================================

; --------------------------------------------------------------------------
; UIntToStr - entero sin signo -> cadena decimal ASCII (conversion propia)
;   Divide entre 10: el residuo es el digito (se apila) y el cociente
;   continua. Al desapilar los digitos salen en el orden correcto.
; ENTRADA : EAX = valor ; EDI -> destino
; SALIDA  : destino con los digitos y un 00h ; EDI -> ese 00h final
; MODIFICA: EDI, EFLAGS
; CONSERVA: EAX, EBX, ECX, EDX (USES)
; USES    : EAX se divide, EBX es el divisor, ECX cuenta digitos y EDX recibe
;           el residuo; EDI queda fuera porque es la salida
; PILA    : ademas de USES, apila un digito por vuelta y los desapila todos
;           con el mismo contador (ECX); queda equilibrada
; --------------------------------------------------------------------------
UIntToStr PROC USES eax ebx ecx edx
    mov  ebx, 10
    xor  ecx, ecx                       ; ECX = cantidad de digitos
uts_div:
    xor  edx, edx                       ; EDX:EAX = dividendo
    div  ebx                            ; EAX = cociente, EDX = residuo
    push edx                            ; guardar el digito
    inc  ecx
    test eax, eax
    jnz  uts_div
uts_out:
    pop  edx                            ; el ultimo digito apilado es el primero
    add  dl, '0'                        ; valor 0..9 -> ASCII '0'..'9'
    PUTCH dl
    loop uts_out
    mov  BYTE PTR [edi], 0              ; terminador 00h
    ret
UIntToStr ENDP

; --------------------------------------------------------------------------
; FormatMXN - centavos -> "pesos.cc MXN"
;   DIV entre 100: cociente = pesos, residuo = centavos.
;   Los centavos se dividen entre 10 para imprimir siempre 2 digitos
;   (residuo 5 -> "05").
; ENTRADA : EAX = centavos ; EDI -> destino (minimo 20 bytes)
; SALIDA  : cadena terminada en 0 ; EDI -> ese 00h final
; MODIFICA: EDI, EFLAGS
; CONSERVA: EAX, EBX, EDX (USES); ECX no se toca (UIntToStr la conserva)
; PILA    : equilibrada
; --------------------------------------------------------------------------
FormatMXN PROC USES eax ebx edx
    mov  ebx, 100
    xor  edx, edx                       ; dividendo = EDX:EAX (EDX = 0)
    div  ebx                            ; EAX = pesos, EDX = centavos (0..99)
    call UIntToStr                      ; escribe los pesos (conserva EDX)
    PUTCH '.'
    mov  eax, edx                       ; EAX = centavos
    mov  ebx, 10
    xor  edx, edx
    div  ebx                            ; EAX = decenas, EDX = unidades
    add  al, '0'
    PUTCH al
    add  dl, '0'
    PUTCH dl
    mov  DWORD PTR [edi], 4E584D20h     ; " MXN" (20h 4Dh 58h 4Eh)
    add  edi, 4
    mov  BYTE PTR [edi], 0
    ret
FormatMXN ENDP

; --------------------------------------------------------------------------
; PrintUInt - muestra un entero con WriteString
; ENTRADA : EAX = valor
; SALIDA  : texto en consola
; MODIFICA: EFLAGS
; CONSERVA: todos los registros (EDX y EDI en USES; EAX lo conserva UIntToStr)
; USES    : EDI (destino) y EDX (cadena a imprimir) son los unicos que altera
; --------------------------------------------------------------------------
PrintUInt PROC USES edx edi
    mov  edi, OFFSET outBuf
    call UIntToStr
    mov  edx, OFFSET outBuf
    call WriteString
    ret
PrintUInt ENDP

; --------------------------------------------------------------------------
; PrintMXN - muestra un importe en centavos como "pesos.cc MXN"
; ENTRADA : EAX = centavos
; SALIDA  : texto en consola
; MODIFICA: EFLAGS
; CONSERVA: todos los registros (EDX y EDI en USES; EAX lo conserva FormatMXN)
; --------------------------------------------------------------------------
PrintMXN PROC USES edx edi
    mov  edi, OFFSET outBuf
    call FormatMXN
    mov  edx, OFFSET outBuf
    call WriteString
    ret
PrintMXN ENDP

; --------------------------------------------------------------------------
; PrintPadded - escribe una cadena y la rellena con espacios hasta un ancho
; ENTRADA : EDX -> cadena ; ECX = ancho de columna
; SALIDA  : texto en consola
; MODIFICA: EFLAGS
; CONSERVA: todos los registros (USES EAX, EBX, ECX: AL para el espacio,
;           EBX = longitud, ECX = contador de relleno; EDX no cambia)
; --------------------------------------------------------------------------
PrintPadded PROC USES eax ebx ecx
    xor  ebx, ebx                       ; EBX = longitud de la cadena
ppd_len:
    cmp  BYTE PTR [edx+ebx], 0          ; buscar el 00h final
    je   ppd_got
    inc  ebx
    jmp  ppd_len
ppd_got:
    call WriteString                    ; EDX -> cadena
    sub  ecx, ebx
    jbe  ppd_end                        ; ya ocupa el ancho completo
ppd_sp:
    mov  al, ' '
    call WriteChar
    loop ppd_sp
ppd_end:
    ret
PrintPadded ENDP

; --------------------------------------------------------------------------
; ShowRecord - imprime una fila del inventario
; ENTRADA : ESI -> registro (se accede con desplazamientos OFS_*)
; SALIDA  : texto en consola
; MODIFICA: EFLAGS
; CONSERVA: todos los registros (USES EAX, ECX, EDX, EDI: valor numerico,
;           ancho de columna, puntero de texto y buffer de formato; ESI es
;           parametro de solo lectura y no cambia)
; --------------------------------------------------------------------------
ShowRecord PROC USES eax ecx edx edi
    PADFIELD OFS_CODE, 10
    PADFIELD OFS_NAME, 27
    mov  eax, [esi+OFS_PRICE]
    mov  edi, OFFSET outBuf
    call FormatMXN
    mov  edx, OFFSET outBuf
    mov  ecx, 16
    call PrintPadded
    mov  eax, [esi+OFS_STOCK]
    call PrintUInt
    call Crlf
    ret
ShowRecord ENDP

; ==========================================================================
; ----------------------  CATALOGO EN MEMORIA  -----------------------------
; ==========================================================================

; --------------------------------------------------------------------------
; CopyStr - copia una cadena terminada en 0 (incluye el 00h)
; ENTRADA : ESI -> origen ; EDI -> destino
; SALIDA  : ESI y EDI quedan despues del 00h copiado
; MODIFICA: ESI, EDI, EFLAGS
; CONSERVA: EAX (USES: AL transporta cada byte)
; --------------------------------------------------------------------------
CopyStr PROC USES eax
cs_loop:
    mov  al, [esi]
    mov  [edi], al
    inc  esi
    inc  edi
    test al, al
    jnz  cs_loop
    ret
CopyStr ENDP

; --------------------------------------------------------------------------
; FindProduct - busca un codigo recorriendo los registros con ESI
; ENTRADA : EDX -> codigo (cadena terminada en 0)
; SALIDA  : CF = 0 -> ESI -> registro encontrado
;           CF = 1 -> ESI = 0 (no existe)
; MODIFICA: ESI, EFLAGS (ESI es resultado: fuera de USES)
; CONSERVA: EAX, ECX, EDI, EDX (USES EAX, ECX, EDI)
; PILA    : ademas de USES hay PUSH ESI / POP ESI por registro revisado; cada
;           camino de salida del ciclo hace su POP
; --------------------------------------------------------------------------
FindProduct PROC USES eax ecx edi
    mov  esi, OFFSET catalog            ; ESI = primer registro
    mov  ecx, prodCount                 ; ECX = registros por revisar
fp_next:
    test ecx, ecx
    jz   fp_none
    push esi                            ; guardar el inicio del registro
    mov  edi, edx                       ; EDI -> codigo buscado
fp_cmp:
    mov  al, [esi]
    cmp  al, [edi]
    jne  fp_diff
    test al, al                         ; ambos terminaron: son iguales
    jz   fp_same
    inc  esi
    inc  edi
    jmp  fp_cmp
fp_same:
    pop  esi                            ; ESI -> inicio del registro
    clc
    ret
fp_diff:
    pop  esi
    add  esi, RECSIZE                   ; siguiente registro
    dec  ecx
    jmp  fp_next
fp_none:
    xor  esi, esi
    stc
    ret
FindProduct ENDP

; --------------------------------------------------------------------------
; ValidateImage - valida una imagen de archivo ANTES de reemplazar el catalogo
;   Comprueba: tamano minimo, marca "TNS1", cantidad 0..10, tamano exacto
;   (8 + cantidad*44), cada codigo, nombre, precio, existencia y duplicados.
; ENTRADA : ESI -> imagen ; ECX = bytes disponibles (leidos)
; SALIDA  : EAX = 0 valida, 3 invalida
; MODIFICA: EAX, EFLAGS
; CONSERVA: EBX, ECX, EDX, ESI, EDI (USES; EAX queda fuera: es el resultado)
; PILA    : ademas de USES, el ciclo de duplicados apila/desapila ESI y EDI
; --------------------------------------------------------------------------
ValidateImage PROC USES ebx ecx edx esi edi
    cld
    cmp  ecx, HDRSIZE
    jb   vi_bad
    cmp  DWORD PTR [esi], MAGIC
    jne  vi_bad
    mov  ebx, [esi+4]                   ; EBX = cantidad declarada
    cmp  ebx, MAXPROD
    ja   vi_bad
    mov  eax, ebx
    mov  edx, RECSIZE
    mul  edx                            ; EAX = cantidad * 44
    add  eax, HDRSIZE
    cmp  eax, ecx                       ; bytes leidos deben coincidir exacto
    jne  vi_bad
    add  esi, HDRSIZE                   ; ESI -> primer registro
    mov  ecx, ebx
    test ecx, ecx
    jz   vi_ok
vi_rec:
    mov  edx, esi
    call ValidateCode
    jc   vi_bad
    lea  edx, [esi+OFS_NAME]
    call ValidateName
    jc   vi_bad
    mov  eax, [esi+OFS_PRICE]
    cmp  eax, 1
    jb   vi_bad
    cmp  eax, MAXPRICE
    ja   vi_bad
    cmp  DWORD PTR [esi+OFS_STOCK], MAXSTOCK
    ja   vi_bad
    add  esi, RECSIZE
    dec  ecx
    jnz  vi_rec
    mov  eax, ebx                       ; volver al primer registro
    mov  edx, RECSIZE
    mul  edx
    sub  esi, eax
    cmp  ebx, 2
    jb   vi_ok
    mov  eax, ebx
    dec  eax                            ; EAX = registros posteriores al actual
vi_outer:
    mov  edi, esi
    add  edi, RECSIZE                   ; EDI -> registro siguiente
    mov  edx, eax
vi_inner:
    push esi
    push edi
    mov  ecx, 7                         ; comparar los 7 caracteres del codigo
    repe cmpsb
    pop  edi
    pop  esi
    je   vi_bad                         ; codigos iguales = duplicado
    add  edi, RECSIZE
    dec  edx
    jnz  vi_inner
    add  esi, RECSIZE
    dec  eax
    jnz  vi_outer
vi_ok:
    xor  eax, eax
    ret
vi_bad:
    mov  eax, 3
    ret
ValidateImage ENDP

; --------------------------------------------------------------------------
; InstallImage - reemplaza el catalogo con una imagen YA validada
; ENTRADA : ESI -> imagen valida
; SALIDA  : catalog y prodCount actualizados
; MODIFICA: EFLAGS
; CONSERVA: todos los registros (USES EAX, ECX, EDX, ESI, EDI)
; USES    : EAX (AL=0 para STOSB), ECX (contador), EDX (cantidad), ESI y EDI
;           (origen y destino de REP MOVSB)
; --------------------------------------------------------------------------
InstallImage PROC USES eax ecx edx esi edi
    cld
    mov  edx, [esi+4]                   ; EDX = cantidad
    add  esi, HDRSIZE                   ; ESI -> primer registro
    CLEARMEM catalog, MAXPROD*RECSIZE   ; limpiar catalogo
    mov  ecx, edx
    imul ecx, ecx, RECSIZE              ; bytes a copiar
    mov  edi, OFFSET catalog
    rep  movsb                          ; copiar registros
    mov  prodCount, edx
    ret
InstallImage ENDP

; --------------------------------------------------------------------------
; SkipEol - salta saltos de linea (0Dh / 0Ah) consecutivos
; ENTRADA : ESI -> texto
; SALIDA  : ESI -> primer caracter que no es salto de linea (o el 00h final)
; MODIFICA: ESI, EFLAGS
; CONSERVA: EAX (USES: AL examina cada caracter)
; --------------------------------------------------------------------------
SkipEol PROC USES eax
se_loop:
    mov  al, [esi]
    cmp  al, 0Dh
    je   se_adv
    cmp  al, 0Ah
    jne  se_end
se_adv:
    inc  esi
    jmp  se_loop
se_end:
    ret
SkipEol ENDP

; --------------------------------------------------------------------------
; ScanField - aisla un campo del texto: avanza hasta ';', 0Dh, 0Ah o 00h y
;             cambia ese delimitador por 00h (el campo queda como cadena)
; ENTRADA : ESI -> inicio del campo
; SALIDA  : EDX -> inicio del campo (cadena terminada en 00h)
;           AL  = delimitador original (';', 0Dh, 0Ah o 0)
;           ESI -> despues del delimitador (si era 00h, ESI queda en el 00h)
; MODIFICA: EAX, EDX, ESI, EFLAGS (los tres son resultado)
; USES    : no lleva; todo lo que altera es salida
; --------------------------------------------------------------------------
ScanField PROC
    mov  edx, esi
sf_loop:
    mov  al, [esi]
    cmp  al, ';'
    je   sf_cut
    cmp  al, 0Dh
    je   sf_cut
    cmp  al, 0Ah
    je   sf_cut
    test al, al
    jz   sf_end
    inc  esi
    jmp  sf_loop
sf_cut:
    mov  BYTE PTR [esi], 0              ; el delimitador pasa a ser fin de cadena
    inc  esi
sf_end:
    ret
ScanField ENDP

; --------------------------------------------------------------------------
; CopyField - copia una cadena con limite de longitud (incluye el 00h)
; ENTRADA : EDX -> origen ; EDI -> destino ; ECX = longitud maxima permitida
; SALIDA  : CF = 0 copiada ; CF = 1 si la cadena supera ECX caracteres
; MODIFICA: EFLAGS
; CONSERVA: EAX, ECX, EDX, ESI, EDI (USES EAX, ECX, ESI, EDI)
; USES    : ECX (limite que se decrementa), ESI y EDI (punteros que avanzan)
;           y EAX (carga cada byte); EDX no se altera
; --------------------------------------------------------------------------
CopyField PROC USES eax ecx esi edi
    mov  esi, edx
cf_loop:
    mov  al, [esi]
    test al, al
    jz   cf_end
    test ecx, ecx
    jz   cf_bad                         ; ya no cabe otro caracter
    mov  [edi], al
    inc  esi
    inc  edi
    dec  ecx
    jmp  cf_loop
cf_end:
    mov  BYTE PTR [edi], 0
    clc
    ret
cf_bad:
    stc
    ret
CopyField ENDP

; --------------------------------------------------------------------------
; ParseText - convierte el texto de loadBuf en registros de 44 bytes (parseImg)
;   Formato: 1a linea "TNS1"; luego CODIGO;NOMBRE;PRECIO;EXISTENCIA por linea.
;   Acepta CRLF o LF y omite lineas vacias. Rechaza: marca incorrecta, mas de
;   10 productos, campos faltantes o sobrantes, campos demasiado largos,
;   precio/existencia mal escritos y bytes 00h dentro del archivo.
;   (La validacion completa de rangos y duplicados la hace ValidateImage.)
; ENTRADA : loadBuf con el texto (00h despues de bytesRead)
; SALIDA  : EAX = 0 correcto (parseCnt y parseRecs llenos), 3 invalido
; MODIFICA: EAX, EFLAGS
; CONSERVA: EBX, ECX, EDX, ESI, EDI (USES; EAX fuera: es el resultado)
; PILA    : ademas de USES, apila/desapila EDI al copiar el nombre
; --------------------------------------------------------------------------
ParseText PROC USES ebx ecx edx esi edi
    cld
    CLEARMEM parseRecs, MAXPROD*RECSIZE ; limpiar la imagen temporal
    mov  parseCnt, 0
    mov  esi, OFFSET loadBuf
    cmp  DWORD PTR [esi], MAGIC         ; "TNS1"
    jne  pt_bad
    add  esi, 4
    mov  al, [esi]                      ; despues de la marca: fin de linea o fin de texto
    test al, al
    jz   pt_hdr
    cmp  al, 0Dh
    je   pt_hdr
    cmp  al, 0Ah
    jne  pt_bad
pt_hdr:
    call SkipEol
    xor  ebx, ebx                       ; EBX = productos leidos
    mov  edi, OFFSET parseRecs          ; EDI -> registro que se llena
pt_line:
    cmp  BYTE PTR [esi], 0
    je   pt_done
    cmp  ebx, MAXPROD                   ; un onceavo producto no cabe
    jae  pt_bad
    call ScanField                      ; --- codigo
    cmp  al, ';'
    jne  pt_bad
    mov  ecx, 7
    call CopyField                      ; EDX -> campo, EDI -> registro + 0
    jc   pt_bad
    call ScanField                      ; --- nombre
    cmp  al, ';'
    jne  pt_bad
    push edi
    add  edi, OFS_NAME
    mov  ecx, MAXNAME
    call CopyField
    pop  edi
    jc   pt_bad
    call ScanField                      ; --- precio ("1899.99" -> centavos)
    cmp  al, ';'
    jne  pt_bad
    call ParsePrice
    jc   pt_bad
    mov  [edi+OFS_PRICE], eax
    call ScanField                      ; --- existencia (ultimo campo)
    cmp  al, ';'
    je   pt_bad                         ; no debe haber un 5o campo
    call ParseUInt
    jc   pt_bad
    cmp  eax, MAXSTOCK
    ja   pt_bad
    mov  [edi+OFS_STOCK], eax
    call SkipEol
    inc  ebx
    add  edi, RECSIZE                   ; siguiente registro
    jmp  pt_line
pt_done:
    mov  eax, OFFSET loadBuf            ; el cursor debe quedar en el 00h agregado
    add  eax, bytesRead                 ; despues del ultimo byte leido
    cmp  esi, eax
    jne  pt_bad                         ; habia un 00h dentro del archivo
    mov  parseCnt, ebx
    xor  eax, eax
    ret
pt_bad:
    mov  eax, 3
    ret
ParseText ENDP

; --------------------------------------------------------------------------
; AppendStr - agrega una cadena (sin su 00h) al final de un buffer
; ENTRADA : ESI -> origen ; EDI -> posicion de escritura
; SALIDA  : ESI -> 00h del origen ; EDI -> despues del ultimo caracter copiado
; MODIFICA: ESI, EDI, EFLAGS
; CONSERVA: EAX (USES: AL transporta cada byte)
; --------------------------------------------------------------------------
AppendStr PROC USES eax
as_loop:
    mov  al, [esi]
    test al, al
    jz   as_end
    mov  [edi], al
    inc  esi
    inc  edi
    jmp  as_loop
as_end:
    ret
AppendStr ENDP

; --------------------------------------------------------------------------
; FormatPrice - centavos -> "pesos.cc" (sin la etiqueta MXN)
; ENTRADA : EAX = centavos ; EDI -> destino
; SALIDA  : cadena terminada en 0 ; EDI -> ese 00h final
; MODIFICA: EDI, EFLAGS
; CONSERVA: EAX, EBX, EDX (los conserva FormatMXN)
; USES    : no lleva; solo altera EDI, que es la salida
; --------------------------------------------------------------------------
FormatPrice PROC
    call FormatMXN                      ; escribe "pesos.cc MXN"
    sub  edi, 4                         ; retroceder sobre " MXN"
    mov  BYTE PTR [edi], 0
    ret
FormatPrice ENDP

; --------------------------------------------------------------------------
; BuildText - genera en saveBuf el texto del inventario:
;     TNS1
;     CODIGO;NOMBRE;PRECIO;EXISTENCIA      (una linea por producto, CRLF)
; ENTRADA : catalog y prodCount
; SALIDA  : EAX = bytes de texto en saveBuf
; MODIFICA: EAX, EFLAGS
; CONSERVA: ECX, ESI, EDI (USES); EBX y EDX no se alteran
; USES    : ECX = contador de productos, ESI = registro actual, EDI = cursor
;           de escritura; EAX queda fuera porque devuelve los bytes
; PILA    : ademas de USES, guarda el inicio del registro con PUSH ESI y lo
;           relee con [ESP] (sin otros PUSH en medio); POP ESI al terminar
; --------------------------------------------------------------------------
BuildText PROC USES ecx esi edi
    mov  edi, OFFSET saveBuf
    mov  DWORD PTR [edi], MAGIC         ; "TNS1"
    add  edi, 4
    mov  WORD PTR [edi], 0A0Dh          ; 0Dh 0Ah = fin de linea
    add  edi, 2
    mov  esi, OFFSET catalog            ; ESI recorre los registros
    mov  ecx, prodCount
    test ecx, ecx
    jz   bt_done
bt_rec:
    push esi                            ; guardar inicio del registro
    call AppendStr                      ; codigo (offset 0)
    PUTCH ';'
    mov  esi, [esp]
    add  esi, OFS_NAME
    call AppendStr                      ; nombre
    PUTCH ';'
    mov  esi, [esp]
    mov  eax, [esi+OFS_PRICE]
    call FormatPrice                    ; precio con punto decimal
    PUTCH ';'                           ; sustituye el 00h
    mov  esi, [esp]
    mov  eax, [esi+OFS_STOCK]
    call UIntToStr                      ; existencia
    mov  WORD PTR [edi], 0A0Dh          ; sustituye el 00h por CR LF
    add  edi, 2
    pop  esi
    add  esi, RECSIZE
    dec  ecx
    jnz  bt_rec
bt_done:
    mov  eax, edi
    sub  eax, OFFSET saveBuf            ; EAX = bytes a escribir
    ret
BuildText ENDP

; --------------------------------------------------------------------------
; LoadFromFile - abre, lee, convierte el TEXTO a una imagen temporal, la
;                valida e instala
;   1) ReadFromFile llena loadBuf (capacidad LOADCAP) y devuelve en EAX los
;      bytes leidos; despues se agrega 00h para poder tratarlo como cadena.
;   2) ParseText convierte cada linea en un registro de 44 bytes (parseImg).
;   3) ValidateImage revisa todo; solo entonces InstallImage reemplaza el
;      catalogo.
; ENTRADA : EDX -> nombre de archivo
; SALIDA  : EAX = 0 correcto, 1 no existe, 2 error de lectura, 3 invalido
;           (si EAX <> 0 el catalogo actual NO se modifica)
; MODIFICA: EAX, EFLAGS
; CONSERVA: EBX, ECX, EDX, ESI, EDI (USES; EAX fuera: es el codigo devuelto)
; USES    : se protege el conjunto completo porque el procedimiento llama a
;           la API de archivos de Irvine32 y no se quiere depender de que
;           registros altera por dentro. (Antes: EBX, ECX, EDX, ESI; se agrega
;           EDI para igualar la proteccion que daba el PUSHAD de InitCatalog.)
; --------------------------------------------------------------------------
LoadFromFile PROC USES ebx ecx edx esi edi
    call OpenInputFile                  ; EDX -> nombre ; EAX = handle
    cmp  eax, INVALID_HANDLE_VALUE
    je   lf_absent
    mov  fileHandle, eax
    mov  edx, OFFSET loadBuf            ; destino de la lectura
    mov  ecx, LOADCAP                   ; capacidad del buffer
    call ReadFromFile                   ; EAX = bytes leidos
    jc   lf_rderr
    mov  bytesRead, eax
    mov  BYTE PTR loadBuf[eax], 0       ; 00h despues del ultimo byte leido
    mov  eax, fileHandle
    call CloseFile
    cmp  bytesRead, LOADCAP             ; lleno el buffer: archivo demasiado grande
    jae  lf_bad
    call ParseText                      ; EAX = 0 / 3
    test eax, eax
    jnz  lf_end
    mov  esi, OFFSET parseImg
    mov  ecx, parseCnt
    imul ecx, ecx, RECSIZE
    add  ecx, HDRSIZE                   ; bytes de la imagen temporal
    call ValidateImage                  ; EAX = 0 / 3
    test eax, eax
    jnz  lf_end
    call InstallImage                   ; solo si todo es valido
    xor  eax, eax
    jmp  lf_end
lf_bad:
    mov  eax, 3
    jmp  lf_end
lf_rderr:
    mov  eax, fileHandle
    call CloseFile
    mov  eax, 2
    jmp  lf_end
lf_absent:
    mov  eax, 1
lf_end:
    ret
LoadFromFile ENDP

; --------------------------------------------------------------------------
; InitCatalog - al iniciar: intenta recuperar inventario.txt; si no existe o
;               es invalido, carga los 5 productos de prueba
; ENTRADA : ninguna
; SALIDA  : catalogo inicializado ; dirty = 0
; MODIFICA: EFLAGS
; CONSERVA: todos los registros
; USES    : EAX, ECX, EDX y ESI se usan para llamar a LoadFromFile,
;           ValidateImage e InstallImage; EBX y EDI se incluyen porque el
;           procedimiento llama a la API de archivos (ver LoadFromFile) y
;           antes estaban cubiertos por PUSHAD
; --------------------------------------------------------------------------
InitCatalog PROC USES eax ebx ecx edx esi edi
    mov  edx, OFFSET defFile
    call LoadFromFile
    test eax, eax
    jnz  ic_default
    SAYUINT msgStartOK, prodCount
    jmp  ic_end
ic_default:
    mov  esi, OFFSET defImage
    mov  ecx, DEFLEN
    call ValidateImage
    test eax, eax
    jnz  ic_end
    call InstallImage
    SAY  msgStartDef
ic_end:
    mov  dirty, 0
    ret
InitCatalog ENDP

; ==========================================================================
; ----------------------  FUNCIONES DEL MENU  ------------------------------
; ==========================================================================

; --------------------------------------------------------------------------
; StoreProduct - NUEVO. Graba en el catalogo el producto preparado en
;                tmpCode/tmpName/tmpPrice/tmpStock. Es el "punto de
;                confirmacion" del alta: se llama solo con datos ya validos.
; ENTRADA : tmpCode, tmpName, tmpPrice, tmpStock (variables); prodCount < MAXPROD
; SALIDA  : registro nuevo en catalog ; prodCount + 1 ; dirty = 1
; MODIFICA: EFLAGS
; CONSERVA: todos los registros
; USES    : EAX y EDX (MUL), ECX (tamano de registro), EBX (puntero al
;           registro nuevo), ESI y EDI (CopyStr)
; --------------------------------------------------------------------------
StoreProduct PROC USES eax ebx ecx edx esi edi
    mov  eax, prodCount
    mov  ecx, RECSIZE
    mul  ecx                            ; EAX = prodCount * 44
    lea  ebx, catalog[eax]              ; EBX -> registro nuevo
    mov  esi, OFFSET tmpCode
    mov  edi, ebx
    call CopyStr
    mov  esi, OFFSET tmpName
    lea  edi, [ebx+OFS_NAME]
    call CopyStr
    mov  eax, tmpPrice
    mov  [ebx+OFS_PRICE], eax
    mov  eax, tmpStock
    mov  [ebx+OFS_STOCK], eax
    inc  prodCount
    mov  dirty, 1
    ret
StoreProduct ENDP

; --------------------------------------------------------------------------
; RegisterProduct - alta de un producto
;   Todo se captura y valida en variables temporales; el catalogo solo se
;   modifica al final (StoreProduct), cuando todos los datos son correctos.
; ENTRADA : ninguna
; SALIDA  : mensaje en consola ; catalogo ampliado si el alta fue valida
; MODIFICA: EFLAGS
; CONSERVA: todos los registros
; USES    : EAX (precio/existencia), EBX y ECX (parametros de ASKSTOCK),
;           EDX (mensajes y cadenas), ESI y EDI (STASHSTR y FindProduct)
; --------------------------------------------------------------------------
RegisterProduct PROC USES eax ebx ecx edx esi edi
    cmp  prodCount, MAXPROD
    jb   rp_room
    FAILTO msgFull, rp_end
rp_room:
    mov  edx, OFFSET pCode
    call AskCode                        ; EDX -> codigo valido
    jc   rp_end
    call FindProduct                    ; CF = 0 -> ya existe
    jc   rp_newcode
    FAILTO msgDup, rp_end
rp_newcode:
    STASHSTR tmpCode
    mov  edx, OFFSET pName
    call AskName                        ; EDX -> nombre valido
    jc   rp_end
    STASHSTR tmpName
    mov  edx, OFFSET pPrice
    call AskPrice                       ; EAX = centavos
    jc   rp_end
    mov  tmpPrice, eax
    ASKSTOCK pStock                     ; EAX = existencia 0..100
    jc   rp_end
    mov  tmpStock, eax
    call StoreProduct                   ; punto de confirmacion
    SAY  msgAdded
rp_end:
    ret
RegisterProduct ENDP

; --------------------------------------------------------------------------
; ListInventory - recorre el catalogo con ESI y muestra cada producto
; ENTRADA : ninguna
; SALIDA  : tabla en consola
; MODIFICA: EFLAGS
; CONSERVA: todos los registros
; USES    : ECX (contador del ciclo) y ESI (registro actual)
; --------------------------------------------------------------------------
ListInventory PROC USES ecx esi
    cmp  prodCount, 0
    jne  lv_some
    FAILTO msgNoProd, lv_end
lv_some:
    SHOWHEADER
    mov  esi, OFFSET catalog            ; ESI -> primer registro
    mov  ecx, prodCount                 ; ECX = contador del ciclo
lv_loop:
    call ShowRecord
    add  esi, RECSIZE                   ; siguiente registro
    dec  ecx
    jnz  lv_loop
lv_end:
    ret
ListInventory ENDP

; --------------------------------------------------------------------------
; SearchProduct - busca por codigo y muestra el producto
; ENTRADA : ninguna
; SALIDA  : fila del producto o aviso en consola
; MODIFICA: EFLAGS
; CONSERVA: todos los registros
; USES    : EAX y EDX (AskCode), ESI (FindProduct devuelve el registro en ESI)
; --------------------------------------------------------------------------
SearchProduct PROC USES eax edx esi
    mov  edx, OFFSET pCodeSrch
    call AskCode
    jc   sr_end
    call FindProduct                    ; ESI -> registro si CF = 0
    jc   sr_nf
    SHOWHEADER
    call ShowRecord
    jmp  sr_end
sr_nf:
    SAY  msgNotFound
sr_end:
    ret
SearchProduct ENDP

; --------------------------------------------------------------------------
; ReceiveStock - suma unidades a un producto sin superar 100
; ENTRADA : ninguna
; SALIDA  : mensaje en consola ; existencia actualizada si cabe
; MODIFICA: EFLAGS
; CONSERVA: todos los registros
; USES    : EAX (cantidad), EBX y ECX (parametros de ASKQTY / nueva existencia),
;           EDX (mensajes), ESI (registro seleccionado)
; --------------------------------------------------------------------------
ReceiveStock PROC USES eax ebx ecx edx esi
    mov  edx, OFFSET pCodeRecv
    call AskCode
    jc   rc_end
    call FindProduct
    jc   rc_nf
    mov  curRec, esi                    ; ESI se vuelve a leer tras ReadString
    ASKQTY pQtyRecv                     ; EAX = 1..100
    jc   rc_end
    mov  esi, curRec
    mov  ebx, [esi+OFS_STOCK]
    add  ebx, eax                       ; existencia propuesta (sin grabar aun)
    cmp  ebx, MAXSTOCK
    ja   rc_over
    mov  [esi+OFS_STOCK], ebx           ; confirmacion
    mov  dirty, 1
    SAYUINT msgRecvOK, ebx
    jmp  rc_end
rc_over:
    SAYUINT msgRecvOver, [esi+OFS_STOCK]
    jmp  rc_end
rc_nf:
    SAY  msgNotFound
rc_end:
    ret
ReceiveStock ENDP

; --------------------------------------------------------------------------
; CalcSale - NUEVO. Calcula el importe de una venta con la regla de descuento
;   importe base = precio * cantidad          (MUL, se prueba CF)
;   si cantidad >= 3: descuento = base*10/100 (DIV entero: descarta fraccion)
;   importe final = base - descuento
;   No modifica ningun dato del sistema (solo calcula).
; ENTRADA : ESI -> registro del producto ; EBX = cantidad
; SALIDA  : CF = 0 -> ECX = importe base, EDI = descuento, EAX = importe final
;           CF = 1 -> desbordamiento de 32 bits (sin resultados validos)
; MODIFICA: EAX, ECX, EDI, EFLAGS (los tres son resultados)
; CONSERVA: EDX (USES), EBX, ESI
; USES    : EDX, porque MUL y DIV lo destruyen y no es parte del resultado.
;           EAX, ECX y EDI quedan fuera: devuelven el importe final, el base
;           y el descuento. Los POP de USES no alteran CF.
; --------------------------------------------------------------------------
CalcSale PROC USES edx
    mov  eax, [esi+OFS_PRICE]
    mul  ebx                            ; EDX:EAX = precio * cantidad
    jc   cs_ovf                         ; CF = 1 si EDX <> 0 (desbordamiento)
    mov  ecx, eax                       ; ECX = importe base
    xor  edi, edi                       ; EDI = descuento (0 por omision)
    cmp  ebx, DISC_MIN
    jb   cs_final                       ; menos de 3 pares: sin descuento
    mov  eax, ecx
    mul  pct                            ; base * 10
    jc   cs_ovf
    xor  edx, edx
    div  cien                           ; EAX = (base*10)/100, residuo descartado
    mov  edi, eax
cs_final:
    mov  eax, ecx
    sub  eax, edi                       ; EAX = importe final
    clc
    ret
cs_ovf:
    stc
    ret
CalcSale ENDP

; --------------------------------------------------------------------------
; CommitSale - NUEVO. Punto de confirmacion de la venta: suma el importe a los
;              ingresos, descuenta la existencia y marca cambios sin guardar.
;              Si los ingresos no caben en 32 bits NO cambia nada.
; ENTRADA : ESI -> registro del producto ; EBX = cantidad ; EAX = importe final
; SALIDA  : CF = 0 -> venta registrada ; CF = 1 -> desbordamiento, sin cambios
; MODIFICA: EFLAGS
; CONSERVA: todos los registros (USES EDX: guarda los ingresos propuestos)
; --------------------------------------------------------------------------
CommitSale PROC USES edx
    mov  edx, income
    add  edx, eax                       ; ingresos propuestos
    jc   cm_ovf                         ; el acumulado no cabe en 32 bits
    mov  income, edx
    sub  [esi+OFS_STOCK], ebx
    mov  dirty, 1
    clc
    ret
cm_ovf:
    stc
    ret
CommitSale ENDP

; --------------------------------------------------------------------------
; ShowSale - NUEVO. Muestra el ticket de una venta aceptada
; ENTRADA : ESI -> registro del producto (ya con la existencia descontada)
;           ECX = importe base ; EDI = descuento
; SALIDA  : texto en consola
; MODIFICA: EFLAGS
; CONSERVA: todos los registros (USES EAX: lo usan las macros SAYMXN/SAYUINT)
; --------------------------------------------------------------------------
ShowSale PROC USES eax
    SAY  msgSold
    SAYMXN msgBase, ecx
    SAY  msgDisc
    mov  eax, edi
    call PrintMXN
    test edi, edi
    jz   sh_no
    SAY  msgDiscYes
    jmp  sh_tot
sh_no:
    SAY  msgDiscNo
sh_tot:
    call Crlf
    mov  eax, ecx
    sub  eax, edi                       ; importe final = base - descuento
    SAYMXN msgFinal, eax
    SAYUINT msgLeft, [esi+OFS_STOCK]
    ret
ShowSale ENDP

; --------------------------------------------------------------------------
; SellProduct - venta de un producto con la regla de descuento por 3+ pares
;   Orquesta: CalcSale (calculo) -> CommitSale (confirmacion) -> ShowSale.
;   Existencias e ingresos se actualizan SOLO en CommitSale.
; ENTRADA : ninguna
; SALIDA  : ticket o mensaje de rechazo en consola
; MODIFICA: EFLAGS
; CONSERVA: todos los registros
; USES    : EAX (cantidad e importe), EBX (cantidad), ECX (importe base),
;           EDX (mensajes), ESI (registro), EDI (descuento)
; --------------------------------------------------------------------------
SellProduct PROC USES eax ebx ecx edx esi edi
    mov  edx, OFFSET pCodeSell
    call AskCode
    jc   sl_end
    call FindProduct
    jc   sl_nf
    mov  curRec, esi
    SHOWHEADER
    call ShowRecord
    ASKQTY pQtySell                     ; EAX = cantidad 1..100
    jc   sl_end
    mov  esi, curRec
    mov  ebx, eax                       ; EBX = cantidad
    cmp  ebx, [esi+OFS_STOCK]
    ja   sl_nostock                     ; venta sin existencia suficiente
    call CalcSale                       ; ECX = base, EDI = descuento, EAX = final
    jc   sl_ovf
    call CommitSale                     ; punto de confirmacion
    jc   sl_ovf
    call ShowSale
    jmp  sl_end
sl_nostock:
    SAYUINT msgNoStock, [esi+OFS_STOCK]
    jmp  sl_end
sl_ovf:
    FAILTO msgOvf, sl_end
sl_nf:
    SAY  msgNotFound
sl_end:
    ret
SellProduct ENDP

; --------------------------------------------------------------------------
; ShowSummary - unidades disponibles, valor del inventario e ingresos
;   valor = suma de (precio * existencia) de todos los productos
; ENTRADA : ninguna
; SALIDA  : resumen en consola
; MODIFICA: EFLAGS
; CONSERVA: todos los registros
; USES    : EAX y EDX (MUL), EBX (unidades), ECX (contador), ESI (registro)
;           y EDI (valor acumulado)
; --------------------------------------------------------------------------
ShowSummary PROC USES eax ebx ecx edx esi edi
    xor  ebx, ebx                       ; EBX = unidades
    xor  edi, edi                       ; EDI = valor del inventario
    mov  esi, OFFSET catalog
    mov  ecx, prodCount
    test ecx, ecx
    jz   ss_show
ss_loop:
    mov  eax, [esi+OFS_STOCK]
    add  ebx, eax
    mov  eax, [esi+OFS_PRICE]
    mul  DWORD PTR [esi+OFS_STOCK]      ; precio * existencia
    jc   ss_ovf
    add  edi, eax
    jc   ss_ovf
    add  esi, RECSIZE
    dec  ecx
    jnz  ss_loop
ss_show:
    SAY  msgSumTitle
    SAYUINT msgSumProd, prodCount
    SAYUINT msgSumUnits, ebx
    SAYMXN msgSumValue, edi
    SAYMXN msgSumInc, income
    jmp  ss_end
ss_ovf:
    SAY  msgOvf
ss_end:
    ret
ShowSummary ENDP

; ==========================================================================
; ----------------------  ARCHIVOS DE DISCO (TXT)  -------------------------
; El formato de archivo y la logica de lectura/escritura NO cambiaron.
; ==========================================================================

; --------------------------------------------------------------------------
; AskFileName - pide el nombre de archivo (Enter = inventario.txt)
; ENTRADA : ninguna
; SALIDA  : EDX -> fileBuf con el nombre ; CF = 1 si es demasiado largo
; MODIFICA: EDX, EFLAGS
; CONSERVA: EAX, ECX, ESI, EDI
; USES    : EAX (longitud devuelta por ReadLine), ESI y EDI (CopyStr).
;           ECX no se toca (ReadLine lo conserva). EDX es la salida.
; --------------------------------------------------------------------------
AskFileName PROC USES eax esi edi
    mov  edx, OFFSET pFile
    call WriteString
    call ReadLine
    jc   afn_bad
    mov  esi, OFFSET defFile            ; vacio -> nombre por omision
    test eax, eax
    jz   afn_copy
    mov  esi, edx                       ; si no, el nombre escrito (inBuf)
afn_copy:
    mov  edi, OFFSET fileBuf
    call CopyStr
    mov  edx, OFFSET fileBuf
    clc
    ret
afn_bad:
    SAY  msgBadFile
    stc
    ret
AskFileName ENDP

; --------------------------------------------------------------------------
; SaveInventory - guarda el inventario como archivo de TEXTO
;   BuildText arma en saveBuf "TNS1" y una linea CODIGO;NOMBRE;PRECIO;EXISTENCIA
;   por producto. Se escribe con WriteToFile y se compara EAX (bytes escritos)
;   con los bytes solicitados para confirmar que se grabo todo.
; ENTRADA : ninguna
; SALIDA  : mensaje en consola ; dirty = 0 si se grabo completo
; MODIFICA: EFLAGS
; CONSERVA: todos los registros
; USES    : conjunto completo (EAX..EDI) por llamar a la API de archivos de
;           Irvine32, igual que cubria el PUSHAD original
; --------------------------------------------------------------------------
SaveInventory PROC USES eax ebx ecx edx esi edi
    call AskFileName
    jc   sv_end
    call BuildText                      ; EAX = bytes de texto
    mov  bytesWanted, eax
    mov  edx, OFFSET fileBuf
    call CreateOutputFile               ; EDX -> nombre ; EAX = handle
    cmp  eax, INVALID_HANDLE_VALUE
    je   sv_err
    mov  fileHandle, eax
    mov  ecx, bytesWanted               ; ECX = bytes solicitados
    mov  edx, OFFSET saveBuf            ; EDX -> texto (EAX sigue siendo el handle)
    call WriteToFile                    ; EAX = bytes escritos
    mov  bytesWritten, eax
    mov  eax, fileHandle
    call CloseFile
    mov  eax, bytesWritten
    cmp  eax, bytesWanted               ; deben coincidir
    jne  sv_err
    mov  dirty, 0
    SAYUINT msgSaveOK, bytesWritten
    jmp  sv_end
sv_err:
    SAY  msgSaveErr
sv_end:
    ret
SaveInventory ENDP

; --------------------------------------------------------------------------
; LoadInventory - opcion del menu para cargar un archivo
; ENTRADA : ninguna
; SALIDA  : mensaje en consola ; catalogo reemplazado solo si el archivo es valido
; MODIFICA: EFLAGS
; CONSERVA: todos los registros
; USES    : EAX (estado de LoadFromFile y AL de la respuesta S/N) y EDX
;           (mensajes y nombre de archivo); LoadFromFile y AskFileName ya
;           conservan EBX, ECX, ESI y EDI
; --------------------------------------------------------------------------
LoadInventory PROC USES eax edx
    cmp  dirty, 0
    je   li_ask
    SAY  msgWarnLoad
    mov  edx, OFFSET pContinue
    call AskLine
    jc   li_end
    mov  al, [edx]
    or   al, 20h
    cmp  al, 's'
    jne  li_end
li_ask:
    call AskFileName
    jc   li_end
    call LoadFromFile                   ; EAX = estado
    cmp  eax, 0
    je   li_ok
    cmp  eax, 1
    je   li_no
    cmp  eax, 2
    je   li_rd
    FAILTO msgLoadBad, li_end
li_no:
    FAILTO msgLoadNo, li_end
li_rd:
    FAILTO msgLoadRd, li_end
li_ok:
    mov  dirty, 0
    SAYUINT msgLoadOK, prodCount
li_end:
    ret
LoadInventory ENDP

; --------------------------------------------------------------------------
; ConfirmExit - avisa si hay cambios sin guardar
; ENTRADA : ninguna
; SALIDA  : EAX = 1 salir, 0 permanecer en el menu
; MODIFICA: EAX, EDX, EFLAGS (EAX es resultado; EDX contiene mensajes)
; USES    : no lleva; todo lo que altera es resultado o ya estaba documentado
;           como modificado, y SaveInventory conserva el resto
; --------------------------------------------------------------------------
ConfirmExit PROC
    cmp  dirty, 0
    je   ce_yes
    SAY  msgUnsaved
    mov  edx, OFFSET pExit
    call AskLine
    jc   ce_no
    cmp  eax, 1
    jne  ce_no
    mov  al, [edx]
    or   al, 20h                        ; a minuscula
    cmp  al, 's'
    je   ce_yes
    cmp  al, 'g'
    jne  ce_no
    call SaveInventory
    cmp  dirty, 0                       ; si no se pudo guardar, no salir
    jne  ce_no
ce_yes:
    mov  eax, 1
    ret
ce_no:
    xor  eax, eax
    ret
ConfirmExit ENDP

END main
