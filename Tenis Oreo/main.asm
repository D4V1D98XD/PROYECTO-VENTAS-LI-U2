; ==========================================================================
; TENIS OREO - Sistema de Ventas e Inventario
; Lenguajes de Interfaz - Unidad 2 - MASM x86 (32 bits) + Irvine32
; Equipo: Leonardo David Garcia Leyva
;         Jesus Armando Gastelum Medina
;         Jose Esteban Villalva Felix
;
; Notas generales
;  * Entrada: SOLO ReadString. Salida de numeros: SOLO WriteString.
;    No se usa ReadDec, ReadInt, ParseDecimal32, WriteDec ni WriteHex.
;  * Precios en centavos enteros (DWORD). Se muestran como pesos.cc MXN.
;  * Registro de producto = 44 bytes (ver estructura abajo). Se recorre con ESI.
;  * Archivo: "TNS1" + DWORD cantidad + cantidad * 44 bytes (binario).
;  * Textos sin acentos para evitar problemas con la pagina de codigos de
;    la consola de Windows.
;  * Convencion de documentacion de cada procedimiento:
;       ENTRADA / SALIDA / MODIFICA (registros alterados al regresar)
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
LOADCAP     EQU HDRSIZE + MAXPROD*RECSIZE + 1   ; capacidad de lectura (+1 para detectar archivo mas grande)
INMAX       EQU 40                      ; maximo de caracteres leidos por ReadString
DISC_MIN    EQU 3                       ; regla: pares minimos para descuento
DISC_PCT    EQU 10                      ; regla: porcentaje de descuento
DEFCOUNT    EQU 5                       ; productos iniciales
DEFLEN      EQU HDRSIZE + DEFCOUNT*RECSIZE
MAGIC       EQU 31534E54h               ; "TNS1" en little-endian (54h 4Eh 53h 31h)

; ---------------------------------------------------------------- macro SAY
; Muestra una cadena terminada en 0. Conserva todos los registros.
SAY MACRO txt
    push edx
    mov  edx, OFFSET txt
    call WriteString
    pop  edx
ENDM

.data
; ---- Imagen del archivo en memoria: DEBEN estar contiguos -----------------
fileMagic   BYTE "TNS1"                 ; +0  marca del formato
prodCount   DWORD 0                     ; +4  cantidad de productos
catalog     BYTE MAXPROD*RECSIZE DUP(0) ; +8  registros de 44 bytes

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
defFile     BYTE "inventario.dat",0
fileHandle  DWORD 0
bytesWanted DWORD 0
bytesRead   DWORD 0
; capacidad = LOADCAP; se reserva 1 byte extra para el terminador 00h
loadBuf     BYTE LOADCAP+1 DUP(0)

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
msgBanner   BYTE 0Dh,0Ah,"=== TENIS OREO - Sistema de Ventas e Inventario ===",0Dh,0Ah,0
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
msgBadName  BYTE "Error: nombre invalido (1 a 25 caracteres imprimibles).",0Dh,0Ah,0
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
pFile       BYTE "Archivo (Enter = inventario.dat): ",0
msgSaveOK   BYTE "Inventario guardado. Bytes escritos: ",0
msgSaveErr  BYTE "Error: no se pudo crear o escribir el archivo completo.",0Dh,0Ah,0
msgLoadOK   BYTE "Inventario cargado. Productos recuperados: ",0
msgLoadNo   BYTE "Error: el archivo no existe.",0Dh,0Ah,0
msgLoadRd   BYTE "Error: no se pudo leer el archivo.",0Dh,0Ah,0
msgLoadBad  BYTE "Error: archivo invalido o danado. El catalogo actual no se modifico.",0Dh,0Ah,0
msgStartDef BYTE "Inicio con los 5 productos de prueba (no se encontro un inventario valido).",0Dh,0Ah,0
msgStartOK  BYTE "Se recupero inventario.dat al iniciar. Productos: ",0
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
    cmp  al, '1'
    jne  m2
    call RegisterProduct
    jmp  m_after
m2: cmp  al, '2'
    jne  m3
    call ListInventory
    jmp  m_after
m3: cmp  al, '3'
    jne  m4
    call SearchProduct
    jmp  m_after
m4: cmp  al, '4'
    jne  m5
    call ReceiveStock
    jmp  m_after
m5: cmp  al, '5'
    jne  m6
    call SellProduct
    jmp  m_after
m6: cmp  al, '6'
    jne  m7
    call ShowSummary
    jmp  m_after
m7: cmp  al, '7'
    jne  m8
    call SaveInventory
    jmp  m_after
m8: cmp  al, '8'
    jne  m9
    call LoadInventory
    jmp  m_after
m9: cmp  al, '9'
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
; --------------------------------------------------------------------------
ReadLine PROC
    push ecx
    mov  edx, OFFSET inBuf              ; EDX = donde guardar la entrada
    mov  ecx, INMAX                     ; ECX = maximo de caracteres
    call ReadString                     ; EAX = caracteres capturados
    cmp  eax, INMAX
    jb   rl_ok
rl_flush:                               ; linea demasiado larga: vaciar el resto
    mov  edx, OFFSET inBuf
    mov  ecx, INMAX
    call ReadString
    cmp  eax, INMAX
    jae  rl_flush
    mov  eax, INMAX
    mov  edx, OFFSET inBuf
    pop  ecx
    stc
    ret
rl_ok:
    mov  edx, OFFSET inBuf
    pop  ecx
    clc
    ret
ReadLine ENDP

; --------------------------------------------------------------------------
; AskLine - muestra un mensaje y lee una linea no vacia
; ENTRADA : EDX -> mensaje (cadena terminada en 0)
; SALIDA  : EAX = longitud, EDX -> inBuf ; CF = 1 si vacia o demasiado larga
;           (el error ya fue mostrado)
; MODIFICA: EAX, EDX, EFLAGS
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
; AskCode - pide y valida un codigo ABC-123
; ENTRADA : EDX -> mensaje
; SALIDA  : EDX -> inBuf con el codigo ; CF = 1 si es invalido
; MODIFICA: EAX, EDX, EFLAGS
; --------------------------------------------------------------------------
AskCode PROC
    call AskLine
    jc   ac_end
    call ValidateCode
    jnc  ac_ok
    SAY  msgBadCode
    stc
ac_end:
    ret
ac_ok:
    clc
    ret
AskCode ENDP

; --------------------------------------------------------------------------
; AskQty - pide una cantidad entera de 1 a 100 (solo digitos)
; ENTRADA : EDX -> mensaje
; SALIDA  : EAX = cantidad ; CF = 1 si es invalida
; MODIFICA: EAX, EDX, EFLAGS
; --------------------------------------------------------------------------
AskQty PROC
    call AskLine
    jc   aq_end
    call ParseUInt
    jc   aq_bad
    cmp  eax, 1
    jb   aq_bad
    cmp  eax, MAXSTOCK
    ja   aq_bad
    clc
    ret
aq_bad:
    SAY  msgBadQty
    stc
aq_end:
    ret
AskQty ENDP

; --------------------------------------------------------------------------
; ValidateCode - formato exacto: 3 letras A-Z, '-', 3 digitos, fin de cadena
; ENTRADA : EDX -> cadena
; SALIDA  : CF = 0 valido, CF = 1 invalido
; MODIFICA: EFLAGS (conserva EAX, ECX, ESI, EDX)
; --------------------------------------------------------------------------
ValidateCode PROC
    push eax
    push ecx
    push esi
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
    jmp  vc_end
vc_bad:
    stc
vc_end:
    pop  esi
    pop  ecx
    pop  eax
    ret
ValidateCode ENDP

; --------------------------------------------------------------------------
; ValidateName - 1 a 25 caracteres imprimibles (32..126)
; ENTRADA : EDX -> cadena terminada en 0
; SALIDA  : CF = 0 valido, CF = 1 invalido
; MODIFICA: EFLAGS (conserva EAX, ECX, ESI, EDX)
; --------------------------------------------------------------------------
ValidateName PROC
    push eax
    push ecx
    push esi
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
    inc  ecx
    cmp  ecx, MAXNAME
    ja   vn_bad                         ; mas de 25 caracteres
    inc  esi
    jmp  vn_loop
vn_end:
    test ecx, ecx                       ; vacio no es valido
    jz   vn_bad
    clc
    jmp  vn_done
vn_bad:
    stc
vn_done:
    pop  esi
    pop  ecx
    pop  eax
    ret
ValidateName ENDP

; --------------------------------------------------------------------------
; ParseUInt - convierte una cadena de digitos a entero (conversion propia)
;             valor = valor*10 + (caracter - '0'), sin ReadDec/ParseDecimal32
; ENTRADA : EDX -> cadena terminada en 0
; SALIDA  : EAX = valor ; CF = 1 si esta vacia, tiene un caracter que no es
;           digito o supera 999999 (evita desbordamiento)
; MODIFICA: EAX, EFLAGS (conserva EBX, ECX, ESI, EDX)
; --------------------------------------------------------------------------
ParseUInt PROC
    push ebx
    push ecx
    push esi
    mov  esi, edx
    xor  eax, eax
    xor  ecx, ecx                       ; ECX = cantidad de digitos
pu_loop:
    movzx ebx, BYTE PTR [esi]
    test bl, bl
    jz   pu_end
    sub  bl, '0'                        ; ASCII -> valor 0..9
    cmp  bl, 9
    ja   pu_bad                         ; no era digito
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
    jmp  pu_done
pu_bad:
    xor  eax, eax
    stc
pu_done:
    pop  esi
    pop  ecx
    pop  ebx
    ret
ParseUInt ENDP

; --------------------------------------------------------------------------
; ParsePrice - convierte "185.50" / "12.05" / "300" a centavos enteros
;   pesos*100 + decimales. Acepta enteros o punto con 1 o 2 decimales.
;   Rechaza: vacio, simbolos, comas, punto sin digitos antes o despues,
;   tercer decimal y valores fuera de 0.01 - 9999.99.
; ENTRADA : EDX -> cadena terminada en 0
; SALIDA  : EAX = centavos ; CF = 1 si es invalido
; MODIFICA: EAX, EFLAGS (conserva EBX, ECX, ESI, EDX)
; --------------------------------------------------------------------------
ParsePrice PROC
    push ebx
    push ecx
    push esi
    mov  esi, edx
    xor  eax, eax                       ; EAX = pesos
    xor  ecx, ecx                       ; ECX = digitos enteros
pp_int:
    movzx ebx, BYTE PTR [esi]
    test bl, bl
    jz   pp_nodot
    cmp  bl, '.'
    je   pp_dot
    sub  bl, '0'
    cmp  bl, 9
    ja   pp_bad
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
    sub  bl, '0'
    cmp  bl, 9
    ja   pp_bad
    imul ebx, ebx, 10                   ; decenas de centavo
    add  eax, ebx
    inc  esi
    movzx ebx, BYTE PTR [esi]           ; segundo decimal (opcional)
    test bl, bl
    jz   pp_range
    sub  bl, '0'
    cmp  bl, 9
    ja   pp_bad
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
    jmp  pp_done
pp_bad:
    xor  eax, eax
    stc
pp_done:
    pop  esi
    pop  ecx
    pop  ebx
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
; MODIFICA: EDI, EFLAGS (conserva EAX, EBX, ECX, EDX)
; --------------------------------------------------------------------------
UIntToStr PROC
    push eax
    push ebx
    push ecx
    push edx
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
    mov  [edi], dl
    inc  edi
    loop uts_out
    mov  BYTE PTR [edi], 0              ; terminador 00h
    pop  edx
    pop  ecx
    pop  ebx
    pop  eax
    ret
UIntToStr ENDP

; --------------------------------------------------------------------------
; FormatMXN - centavos -> "pesos.cc MXN"
;   DIV entre 100: cociente = pesos, residuo = centavos.
;   Los centavos se dividen entre 10 para imprimir siempre 2 digitos
;   (residuo 5 -> "05").
; ENTRADA : EAX = centavos ; EDI -> destino (minimo 20 bytes)
; SALIDA  : cadena terminada en 0 ; EDI -> ese 00h final
; MODIFICA: EDI, EFLAGS (conserva EAX, EBX, EDX)
; --------------------------------------------------------------------------
FormatMXN PROC
    push eax
    push ebx
    push edx
    mov  ebx, 100
    xor  edx, edx                       ; dividendo = EDX:EAX (EDX = 0)
    div  ebx                            ; EAX = pesos, EDX = centavos (0..99)
    call UIntToStr                      ; escribe los pesos
    mov  BYTE PTR [edi], '.'
    inc  edi
    mov  eax, edx                       ; EAX = centavos
    mov  ebx, 10
    xor  edx, edx
    div  ebx                            ; EAX = decenas, EDX = unidades
    add  al, '0'
    mov  [edi], al
    inc  edi
    add  dl, '0'
    mov  [edi], dl
    inc  edi
    mov  DWORD PTR [edi], 4E584D20h     ; " MXN" (20h 4Dh 58h 4Eh)
    add  edi, 4
    mov  BYTE PTR [edi], 0
    pop  edx
    pop  ebx
    pop  eax
    ret
FormatMXN ENDP

; --------------------------------------------------------------------------
; PrintUInt - muestra un entero con WriteString
; ENTRADA : EAX = valor
; SALIDA  : texto en consola
; MODIFICA: EFLAGS (conserva todos los registros)
; --------------------------------------------------------------------------
PrintUInt PROC
    pushad
    mov  edi, OFFSET outBuf
    call UIntToStr
    mov  edx, OFFSET outBuf
    call WriteString
    popad
    ret
PrintUInt ENDP

; --------------------------------------------------------------------------
; PrintMXN - muestra un importe en centavos como "pesos.cc MXN"
; ENTRADA : EAX = centavos
; SALIDA  : texto en consola
; MODIFICA: EFLAGS (conserva todos los registros)
; --------------------------------------------------------------------------
PrintMXN PROC
    pushad
    mov  edi, OFFSET outBuf
    call FormatMXN
    mov  edx, OFFSET outBuf
    call WriteString
    popad
    ret
PrintMXN ENDP

; --------------------------------------------------------------------------
; PrintPadded - escribe una cadena y la rellena con espacios hasta un ancho
; ENTRADA : EDX -> cadena ; ECX = ancho de columna
; SALIDA  : texto en consola
; MODIFICA: EFLAGS (conserva todos los registros)
; --------------------------------------------------------------------------
PrintPadded PROC
    pushad
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
    popad
    ret
PrintPadded ENDP

; --------------------------------------------------------------------------
; ShowHeader - encabezado de la tabla de productos
; MODIFICA: EFLAGS (conserva todos los registros)
; --------------------------------------------------------------------------
ShowHeader PROC
    SAY  msgHeader
    ret
ShowHeader ENDP

; --------------------------------------------------------------------------
; ShowRecord - imprime una fila del inventario
; ENTRADA : ESI -> registro (se accede con desplazamientos OFS_*)
; MODIFICA: EFLAGS (conserva todos los registros)
; --------------------------------------------------------------------------
ShowRecord PROC
    pushad
    lea  edx, [esi+OFS_CODE]
    mov  ecx, 10
    call PrintPadded
    lea  edx, [esi+OFS_NAME]
    mov  ecx, 27
    call PrintPadded
    mov  eax, [esi+OFS_PRICE]
    mov  edi, OFFSET outBuf
    call FormatMXN
    mov  edx, OFFSET outBuf
    mov  ecx, 16
    call PrintPadded
    mov  eax, [esi+OFS_STOCK]
    call PrintUInt
    call Crlf
    popad
    ret
ShowRecord ENDP

; ==========================================================================
; ----------------------  CATALOGO EN MEMORIA  -----------------------------
; ==========================================================================

; --------------------------------------------------------------------------
; CopyStr - copia una cadena terminada en 0 (incluye el 00h)
; ENTRADA : ESI -> origen ; EDI -> destino
; SALIDA  : ESI y EDI quedan despues del 00h copiado
; MODIFICA: ESI, EDI, EFLAGS (conserva EAX)
; --------------------------------------------------------------------------
CopyStr PROC
    push eax
cs_loop:
    mov  al, [esi]
    mov  [edi], al
    inc  esi
    inc  edi
    test al, al
    jnz  cs_loop
    pop  eax
    ret
CopyStr ENDP

; --------------------------------------------------------------------------
; FindProduct - busca un codigo recorriendo los registros con ESI
; ENTRADA : EDX -> codigo (cadena terminada en 0)
; SALIDA  : CF = 0 -> ESI -> registro encontrado
;           CF = 1 -> ESI = 0 (no existe)
; MODIFICA: ESI, EFLAGS (conserva EAX, ECX, EDX, EDI)
; --------------------------------------------------------------------------
FindProduct PROC
    push eax
    push ecx
    push edi
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
    jmp  fp_end
fp_diff:
    pop  esi
    add  esi, RECSIZE                   ; siguiente registro
    dec  ecx
    jmp  fp_next
fp_none:
    xor  esi, esi
    stc
fp_end:
    pop  edi
    pop  ecx
    pop  eax
    ret
FindProduct ENDP

; --------------------------------------------------------------------------
; ValidateImage - valida una imagen de archivo ANTES de reemplazar el catalogo
;   Comprueba: tamano minimo, marca "TNS1", cantidad 0..10, tamano exacto
;   (8 + cantidad*44), cada codigo, nombre, precio, existencia y duplicados.
; ENTRADA : ESI -> imagen ; ECX = bytes disponibles (leidos)
; SALIDA  : EAX = 0 valida, 3 invalida
; MODIFICA: EAX, EFLAGS (conserva EBX, ECX, EDX, ESI, EDI)
; --------------------------------------------------------------------------
ValidateImage PROC
    push ebx
    push ecx
    push edx
    push esi
    push edi
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
    jmp  vi_end
vi_bad:
    mov  eax, 3
vi_end:
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    ret
ValidateImage ENDP

; --------------------------------------------------------------------------
; InstallImage - reemplaza el catalogo con una imagen YA validada
; ENTRADA : ESI -> imagen valida
; SALIDA  : catalog y prodCount actualizados
; MODIFICA: EFLAGS (conserva todos los registros)
; --------------------------------------------------------------------------
InstallImage PROC
    push eax
    push ecx
    push edx
    push esi
    push edi
    cld
    mov  edx, [esi+4]                   ; EDX = cantidad
    add  esi, HDRSIZE                   ; ESI -> primer registro
    mov  edi, OFFSET catalog
    mov  ecx, MAXPROD*RECSIZE
    xor  al, al
    rep  stosb                          ; limpiar catalogo
    mov  ecx, edx
    imul ecx, ecx, RECSIZE              ; bytes a copiar
    mov  edi, OFFSET catalog
    rep  movsb                          ; copiar registros
    mov  prodCount, edx
    pop  edi
    pop  esi
    pop  edx
    pop  ecx
    pop  eax
    ret
InstallImage ENDP

; --------------------------------------------------------------------------
; LoadFromFile - abre, lee, valida e instala un archivo de inventario
; ENTRADA : EDX -> nombre de archivo
; SALIDA  : EAX = 0 correcto, 1 no existe, 2 error de lectura, 3 invalido
;           (si EAX <> 0 el catalogo actual NO se modifica)
; MODIFICA: EAX, EFLAGS (conserva EBX, ECX, EDX, ESI)
; --------------------------------------------------------------------------
LoadFromFile PROC
    push ebx
    push ecx
    push edx
    push esi
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
    mov  esi, OFFSET loadBuf
    mov  ecx, bytesRead
    call ValidateImage                  ; EAX = 0 / 3
    test eax, eax
    jnz  lf_end
    call InstallImage                   ; solo si todo es valido
    xor  eax, eax
    jmp  lf_end
lf_rderr:
    mov  eax, fileHandle
    call CloseFile
    mov  eax, 2
    jmp  lf_end
lf_absent:
    mov  eax, 1
lf_end:
    pop  esi
    pop  edx
    pop  ecx
    pop  ebx
    ret
LoadFromFile ENDP

; --------------------------------------------------------------------------
; InitCatalog - al iniciar: intenta recuperar inventario.dat; si no existe o
;               es invalido, carga los 5 productos de prueba
; MODIFICA: EFLAGS (conserva todos los registros)
; --------------------------------------------------------------------------
InitCatalog PROC
    pushad
    mov  edx, OFFSET defFile
    call LoadFromFile
    test eax, eax
    jnz  ic_default
    SAY  msgStartOK
    mov  eax, prodCount
    call PrintUInt
    call Crlf
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
    popad
    ret
InitCatalog ENDP

; ==========================================================================
; ----------------------  FUNCIONES DEL MENU  ------------------------------
; ==========================================================================

; --------------------------------------------------------------------------
; RegisterProduct - alta de un producto
;   Todo se captura y valida en variables temporales; el catalogo solo se
;   modifica al final, cuando todos los datos son correctos.
; MODIFICA: EFLAGS (conserva todos los registros)
; --------------------------------------------------------------------------
RegisterProduct PROC
    pushad
    cmp  prodCount, MAXPROD
    jb   rp_room
    SAY  msgFull
    jmp  rp_end
rp_room:
    mov  edx, OFFSET pCode
    call AskCode                        ; EDX -> codigo valido
    jc   rp_end
    call FindProduct                    ; CF = 0 -> ya existe
    jc   rp_newcode
    SAY  msgDup
    jmp  rp_end
rp_newcode:
    mov  esi, edx
    mov  edi, OFFSET tmpCode
    call CopyStr
    mov  edx, OFFSET pName
    call AskLine
    jc   rp_end
    call ValidateName
    jnc  rp_nameOK
    SAY  msgBadName
    jmp  rp_end
rp_nameOK:
    mov  esi, edx
    mov  edi, OFFSET tmpName
    call CopyStr
    mov  edx, OFFSET pPrice
    call AskLine
    jc   rp_end
    call ParsePrice
    jnc  rp_priceOK
    SAY  msgBadPrice
    jmp  rp_end
rp_priceOK:
    mov  tmpPrice, eax
    mov  edx, OFFSET pStock
    call AskLine
    jc   rp_end
    call ParseUInt
    jc   rp_badStock
    cmp  eax, MAXSTOCK
    jbe  rp_stockOK
rp_badStock:
    SAY  msgBadStock
    jmp  rp_end
rp_stockOK:
    mov  tmpStock, eax
    ; ---- punto de confirmacion: todo es valido, ahora si se modifica ----
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
    SAY  msgAdded
rp_end:
    popad
    ret
RegisterProduct ENDP

; --------------------------------------------------------------------------
; ListInventory - recorre el catalogo con ESI y muestra cada producto
; MODIFICA: EFLAGS (conserva todos los registros)
; --------------------------------------------------------------------------
ListInventory PROC
    pushad
    cmp  prodCount, 0
    jne  lv_some
    SAY  msgNoProd
    jmp  lv_end
lv_some:
    call ShowHeader
    mov  esi, OFFSET catalog            ; ESI -> primer registro
    mov  ecx, prodCount                 ; ECX = contador del ciclo
lv_loop:
    call ShowRecord
    add  esi, RECSIZE                   ; siguiente registro
    dec  ecx
    jnz  lv_loop
lv_end:
    popad
    ret
ListInventory ENDP

; --------------------------------------------------------------------------
; SearchProduct - busca por codigo y muestra el producto
; MODIFICA: EFLAGS (conserva todos los registros)
; --------------------------------------------------------------------------
SearchProduct PROC
    pushad
    mov  edx, OFFSET pCodeSrch
    call AskCode
    jc   sr_end
    call FindProduct                    ; ESI -> registro si CF = 0
    jc   sr_nf
    call ShowHeader
    call ShowRecord
    jmp  sr_end
sr_nf:
    SAY  msgNotFound
sr_end:
    popad
    ret
SearchProduct ENDP

; --------------------------------------------------------------------------
; ReceiveStock - suma unidades a un producto sin superar 100
; MODIFICA: EFLAGS (conserva todos los registros)
; --------------------------------------------------------------------------
ReceiveStock PROC
    pushad
    mov  edx, OFFSET pCodeRecv
    call AskCode
    jc   rc_end
    call FindProduct
    jc   rc_nf
    mov  curRec, esi                    ; ESI se vuelve a leer tras ReadString
    mov  edx, OFFSET pQtyRecv
    call AskQty                         ; EAX = 1..100
    jc   rc_end
    mov  esi, curRec
    mov  ebx, [esi+OFS_STOCK]
    add  ebx, eax                       ; existencia propuesta (sin grabar aun)
    cmp  ebx, MAXSTOCK
    ja   rc_over
    mov  [esi+OFS_STOCK], ebx           ; confirmacion
    mov  dirty, 1
    SAY  msgRecvOK
    mov  eax, ebx
    call PrintUInt
    call Crlf
    jmp  rc_end
rc_over:
    SAY  msgRecvOver
    mov  eax, [esi+OFS_STOCK]
    call PrintUInt
    call Crlf
    jmp  rc_end
rc_nf:
    SAY  msgNotFound
rc_end:
    popad
    ret
ReceiveStock ENDP

; --------------------------------------------------------------------------
; SellProduct - venta de un producto con la regla de descuento por 3+ pares
;   importe base = precio * cantidad          (MUL, se prueba CF)
;   si cantidad >= 3: descuento = base*10/100 (DIV entero: descarta fraccion)
;   importe final = base - descuento
;   Existencias e ingresos se actualizan SOLO al final (punto de confirmacion).
; MODIFICA: EFLAGS (conserva todos los registros)
; --------------------------------------------------------------------------
SellProduct PROC
    pushad
    mov  edx, OFFSET pCodeSell
    call AskCode
    jc   sl_end
    call FindProduct
    jc   sl_nf
    mov  curRec, esi
    call ShowHeader
    call ShowRecord
    mov  edx, OFFSET pQtySell
    call AskQty                         ; EAX = cantidad 1..100
    jc   sl_end
    mov  esi, curRec
    mov  ebx, eax                       ; EBX = cantidad
    cmp  ebx, [esi+OFS_STOCK]
    ja   sl_nostock                     ; venta sin existencia suficiente
    mov  eax, [esi+OFS_PRICE]
    mul  ebx                            ; EDX:EAX = precio * cantidad
    jc   sl_ovf                         ; CF = 1 si EDX <> 0 (desbordamiento)
    mov  ecx, eax                       ; ECX = importe base
    xor  edi, edi                       ; EDI = descuento (0 por omision)
    cmp  ebx, DISC_MIN
    jb   sl_calc                        ; menos de 3 pares: sin descuento
    mov  eax, ecx
    mul  pct                            ; base * 10
    jc   sl_ovf
    xor  edx, edx
    div  cien                           ; EAX = (base*10)/100, residuo descartado
    mov  edi, eax
sl_calc:
    mov  eax, ecx
    sub  eax, edi                       ; EAX = importe final
    mov  edx, income
    add  edx, eax                       ; ingresos propuestos
    jc   sl_ovf                         ; el acumulado no cabe en 32 bits
    ; ---- punto de confirmacion: aqui se modifican los datos ----
    mov  income, edx
    sub  [esi+OFS_STOCK], ebx
    mov  dirty, 1
    SAY  msgSold
    SAY  msgBase
    mov  eax, ecx
    call PrintMXN
    call Crlf
    SAY  msgDisc
    mov  eax, edi
    call PrintMXN
    test edi, edi
    jz   sl_msgNo
    SAY  msgDiscYes
    jmp  sl_tot
sl_msgNo:
    SAY  msgDiscNo
sl_tot:
    call Crlf
    SAY  msgFinal
    mov  eax, ecx
    sub  eax, edi
    call PrintMXN
    call Crlf
    SAY  msgLeft
    mov  eax, [esi+OFS_STOCK]
    call PrintUInt
    call Crlf
    jmp  sl_end
sl_nostock:
    SAY  msgNoStock
    mov  eax, [esi+OFS_STOCK]
    call PrintUInt
    call Crlf
    jmp  sl_end
sl_ovf:
    SAY  msgOvf
    jmp  sl_end
sl_nf:
    SAY  msgNotFound
sl_end:
    popad
    ret
SellProduct ENDP

; --------------------------------------------------------------------------
; ShowSummary - unidades disponibles, valor del inventario e ingresos
;   valor = suma de (precio * existencia) de todos los productos
; MODIFICA: EFLAGS (conserva todos los registros)
; --------------------------------------------------------------------------
ShowSummary PROC
    pushad
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
    SAY  msgSumProd
    mov  eax, prodCount
    call PrintUInt
    call Crlf
    SAY  msgSumUnits
    mov  eax, ebx
    call PrintUInt
    call Crlf
    SAY  msgSumValue
    mov  eax, edi
    call PrintMXN
    call Crlf
    SAY  msgSumInc
    mov  eax, income
    call PrintMXN
    call Crlf
    jmp  ss_end
ss_ovf:
    SAY  msgOvf
ss_end:
    popad
    ret
ShowSummary ENDP

; ==========================================================================
; ----------------------  ARCHIVOS DE DISCO  -------------------------------
; ==========================================================================

; --------------------------------------------------------------------------
; AskFileName - pide el nombre de archivo (Enter = inventario.dat)
; ENTRADA : ninguna
; SALIDA  : EDX -> fileBuf con el nombre ; CF = 1 si es demasiado largo
; MODIFICA: EDX, EFLAGS (conserva EAX, ECX, ESI, EDI)
; --------------------------------------------------------------------------
AskFileName PROC
    push eax
    push ecx
    push esi
    push edi
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
    pop  edi
    pop  esi
    pop  ecx
    pop  eax
    clc
    ret
afn_bad:
    SAY  msgBadFile
    pop  edi
    pop  esi
    pop  ecx
    pop  eax
    stc
    ret
AskFileName ENDP

; --------------------------------------------------------------------------
; SaveInventory - guarda "TNS1" + cantidad + registros en un archivo
;   La imagen ya esta contigua en memoria (fileMagic, prodCount, catalog).
;   Bytes a escribir = 8 + cantidad * 44. Se compara con lo escrito (EAX
;   despues de WriteToFile) para confirmar que se grabo todo.
; MODIFICA: EFLAGS (conserva todos los registros)
; --------------------------------------------------------------------------
SaveInventory PROC
    pushad
    call AskFileName
    jc   sv_end
    call CreateOutputFile               ; EDX -> nombre ; EAX = handle
    cmp  eax, INVALID_HANDLE_VALUE
    je   sv_err
    mov  fileHandle, eax
    mov  eax, prodCount
    mov  ecx, RECSIZE
    mul  ecx
    add  eax, HDRSIZE
    mov  bytesWanted, eax
    mov  ecx, eax                       ; ECX = bytes solicitados
    mov  eax, fileHandle                ; EAX = handle
    mov  edx, OFFSET fileMagic          ; EDX -> inicio de la imagen
    call WriteToFile                    ; EAX = bytes escritos
    mov  bytesRead, eax                 ; (se reutiliza como "bytes escritos")
    mov  eax, fileHandle
    call CloseFile
    mov  eax, bytesRead
    cmp  eax, bytesWanted               ; deben coincidir
    jne  sv_err
    mov  dirty, 0
    SAY  msgSaveOK
    call PrintUInt
    call Crlf
    jmp  sv_end
sv_err:
    SAY  msgSaveErr
sv_end:
    popad
    ret
SaveInventory ENDP

; --------------------------------------------------------------------------
; LoadInventory - opcion del menu para cargar un archivo
; MODIFICA: EFLAGS (conserva todos los registros)
; --------------------------------------------------------------------------
LoadInventory PROC
    pushad
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
    SAY  msgLoadBad
    jmp  li_end
li_no:
    SAY  msgLoadNo
    jmp  li_end
li_rd:
    SAY  msgLoadRd
    jmp  li_end
li_ok:
    mov  dirty, 0
    SAY  msgLoadOK
    mov  eax, prodCount
    call PrintUInt
    call Crlf
li_end:
    popad
    ret
LoadInventory ENDP

; --------------------------------------------------------------------------
; ConfirmExit - avisa si hay cambios sin guardar
; SALIDA  : EAX = 1 salir, 0 permanecer en el menu
; MODIFICA: EAX, EDX, EFLAGS
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