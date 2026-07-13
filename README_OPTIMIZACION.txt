Proyecto optimizado manteniendo las funcionalidades existentes.

Cambios aplicados:
- Renderiza únicamente la ventana visible de velas.
- Agrupa velas por píxel cuando hay demasiadas velas en pantalla.
- Agrupa puntos ATR cuando hay más puntos que píxeles útiles.
- El crosshair ya no redibuja todo el gráfico; solo actualiza la capa del crosshair.
- Se limita el render durante arrastre/rueda usando after(16), aproximando 60 FPS.
- Se reducen etiquetas de tiempo y escala para evitar saturación de textos en Tk.
- Se conservan CSV, temporalidades, ATR, volumen, crosshair, Auto/Fija, zoom y arrastres existentes.

Ejecución:
perl market.pl 2026_03.csv
