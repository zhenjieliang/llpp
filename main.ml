type under =
    | Unone
    | Ulinkuri of string
    | Ulinkgoto of (int * int)
    | Utext of facename
and facename = string;;

let log fmt = Printf.kprintf prerr_endline fmt;;
let dolog fmt = Printf.kprintf prerr_endline fmt;;

external init : Unix.file_descr -> unit = "ml_init";;
external draw : (int * int * int * int * bool) -> string  -> unit = "ml_draw";;
external seltext : string -> (int * int * int * int) -> int -> unit =
  "ml_seltext";;
external copysel : string ->  unit = "ml_copysel";;
external getpdimrect : int -> float array = "ml_getpdimrect";;
external whatsunder : string -> int -> int -> under = "ml_whatsunder";;

type mpos = int * int
and mstate =
    | Msel of (mpos * mpos)
    | Mpan of mpos
    | Mscroll
    | Mnone
;;

type 'a circbuf =
    { store : 'a array
    ; mutable rc : int
    ; mutable wc : int
    ; mutable len : int
    }
;;

type textentry = (char * string * onhist option * onkey * ondone)
and onkey = string -> int -> te
and ondone = string -> unit
and onhist = histcmd -> string
and histcmd = HCnext | HCprev | HCfirst | HClast
and te =
    | TEstop
    | TEdone of string
    | TEcont of string
    | TEswitch of textentry
;;

let cbnew n v =
  { store = Array.create n v
  ; rc = 0
  ; wc = 0
  ; len = 0
  }
;;

let cblen b = Array.length b.store;;

let cbput b v =
  let len = cblen b in
  b.store.(b.wc) <- v;
  b.wc <- (b.wc + 1) mod len;
  b.len <- min (b.len + 1) len;
;;

let cbpeekw b = b.store.(b.wc);;

let cbget b dir =
  if b.len = 0
  then b.store.(0)
  else
    let rc = b.rc + dir in
    let rc = if rc = -1 then b.len - 1 else rc in
    let rc = if rc = b.len then 0 else rc in
    b.rc <- rc;
    b.store.(rc);
;;

let cbrfollowlen b =
  b.rc <- b.len;
;;

let cbclear b v =
  b.len <- 0;
  Array.fill b.store 0 (Array.length b.store) v;
;;

type layout =
    { pageno : int
    ; pagedimno : int
    ; pagew : int
    ; pageh : int
    ; pagedispy : int
    ; pagey : int
    ; pagevh : int
    }
;;

type conf =
    { mutable scrollw : int
    ; mutable scrollh : int
    ; mutable icase : bool
    ; mutable preload : bool
    ; mutable pagebias : int
    ; mutable verbose : bool
    ; mutable scrollincr : int
    ; mutable maxhfit : bool
    ; mutable crophack : bool
    ; mutable autoscroll : bool
    ; mutable showall : bool
    ; mutable hlinks : bool
    ; mutable underinfo : bool
    ; mutable interpagespace : int
    ; mutable zoom : float
    ; mutable presentation : bool
    ; mutable angle : int
    }
;;

type outline = string * int * int * float;;
type outlines =
    | Oarray of outline array
    | Olist of outline list
    | Onarrow of outline array * outline array
;;

type rect = (float * float * float * float * float * float * float * float);;

type state =
    { mutable csock : Unix.file_descr
    ; mutable ssock : Unix.file_descr
    ; mutable w : int
    ; mutable h : int
    ; mutable winw : int
    ; mutable x : int
    ; mutable y : int
    ; mutable ty : float
    ; mutable maxy : int
    ; mutable layout : layout list
    ; pagemap : ((int * int * int), string) Hashtbl.t
    ; mutable pdims : (int * int * int) list
    ; mutable pagecount : int
    ; pagecache : string circbuf
    ; mutable rendering : bool
    ; mutable mstate : mstate
    ; mutable searchpattern : string
    ; mutable rects : (int * int * rect) list
    ; mutable rects1 : (int * int * rect) list
    ; mutable text : string
    ; mutable fullscreen : (int * int) option
    ; mutable textentry : textentry option
    ; mutable outlines : outlines
    ; mutable outline : (bool * int * int * outline array * string) option
    ; mutable bookmarks : outline list
    ; mutable path : string
    ; mutable password : string
    ; mutable invalidated : int
    ; mutable colorscale : float
    ; hists : hists
    }
and hists =
    { pat : string circbuf
    ; pag : string circbuf
    ; nav : float circbuf
    }
;;

let conf =
  { scrollw = 7
  ; scrollh = 12
  ; icase = true
  ; preload = true
  ; pagebias = 0
  ; verbose = false
  ; scrollincr = 24
  ; maxhfit = true
  ; crophack = false
  ; autoscroll = false
  ; showall = false
  ; hlinks = false
  ; underinfo = false
  ; interpagespace = 2
  ; zoom = 1.0
  ; presentation = false
  ; angle = 0
  }
;;

let state =
  { csock = Unix.stdin
  ; ssock = Unix.stdin
  ; w = 900
  ; h = 900
  ; winw = 900
  ; y = 0
  ; x = 0
  ; ty = 0.0
  ; layout = []
  ; maxy = max_int
  ; pagemap = Hashtbl.create 10
  ; pagecache = cbnew 10 ""
  ; pdims = []
  ; pagecount = 0
  ; rendering = false
  ; mstate = Mnone
  ; rects = []
  ; rects1 = []
  ; text = ""
  ; fullscreen = None
  ; textentry = None
  ; searchpattern = ""
  ; outlines = Olist []
  ; outline = None
  ; bookmarks = []
  ; path = ""
  ; password = ""
  ; invalidated = 0
  ; hists =
      { nav = cbnew 100 0.0
      ; pat = cbnew 20 ""
      ; pag = cbnew 10 ""
      }
  ; colorscale = 1.0
  }
;;

let vlog fmt =
  if conf.verbose
  then
    Printf.kprintf prerr_endline fmt
  else
    Printf.kprintf ignore fmt
;;

let writecmd fd s =
  let len = String.length s in
  let n = 4 + len in
  let b = Buffer.create n in
  Buffer.add_char b (Char.chr ((len lsr 24) land 0xff));
  Buffer.add_char b (Char.chr ((len lsr 16) land 0xff));
  Buffer.add_char b (Char.chr ((len lsr  8) land 0xff));
  Buffer.add_char b (Char.chr ((len lsr  0) land 0xff));
  Buffer.add_string b s;
  let s' = Buffer.contents b in
  let n' = Unix.write fd s' 0 n in
  if n' != n then failwith "write failed";
;;

let readcmd fd =
  let s = "xxxx" in
  let n = Unix.read fd s 0 4 in
  if n != 4 then failwith "incomplete read(len)";
  let len = 0
    lor (Char.code s.[0] lsl 24)
    lor (Char.code s.[1] lsl 16)
    lor (Char.code s.[2] lsl  8)
    lor (Char.code s.[3] lsl  0)
  in
  let s = String.create len in
  let n = Unix.read fd s 0 len in
  if n != len then failwith "incomplete read(data)";
  s
;;

let yratio y =
  if y = state.maxy
  then 1.0
  else float y /. float state.maxy
;;

let makecmd s l =
  let b = Buffer.create 10 in
  Buffer.add_string b s;
  let rec combine = function
    | [] -> b
    | x :: xs ->
        Buffer.add_char b ' ';
        let s =
          match x with
          | `b b -> if b then "1" else "0"
          | `s s -> s
          | `i i -> string_of_int i
          | `f f -> string_of_float f
          | `I f -> string_of_int (truncate f)
        in
        Buffer.add_string b s;
        combine xs;
  in
  combine l;
;;

let wcmd s l =
  let cmd = Buffer.contents (makecmd s l) in
  writecmd state.csock cmd;
;;

let calcips h =
  if conf.presentation
  then
    let d = state.h - h in
    max 0 ((d + 1) / 2)
  else
    conf.interpagespace
;;

let calcheight () =
  let rec f pn ph pi fh l =
    match l with
    | (n, _, h) :: rest ->
        let ips = calcips h in
        let fh =
          if conf.presentation
          then fh+ips
          else fh
        in
        let fh = fh + ((n - pn) * (ph + pi)) in
        f n h ips fh rest

    | [] ->
        let inc =
          if conf.presentation
          then 0
          else -pi
        in
        let fh = fh + ((state.pagecount - pn) * (ph + pi)) + inc in
        max 0 fh
  in
  let fh = f 0 0 0 0 state.pdims in
  fh;
;;

let getpageyh pageno =
  let rec f pn ph pi y l =
    match l with
    | (n, _, h) :: rest ->
        let ips = calcips h in
        if n >= pageno
        then
          if conf.presentation && n = pageno
          then
            y + (pageno - pn) * (ph + pi) + pi, h
          else
            y + (pageno - pn) * (ph + pi), h
        else
          let y = y + (if conf.presentation then pi else 0) in
          let y = y + (n - pn) * (ph + pi) in
          f n h ips y rest

    | [] ->
        y + (pageno - pn) * (ph + pi), ph
  in
  f 0 0 0 0 state.pdims
;;

let getpagey pageno = fst (getpageyh pageno);;

let layout y sh =
  let rec f ~pageno ~pdimno ~prev ~py ~dy ~pdims ~cacheleft ~accu =
    let ((w, h, ips) as curr), rest, pdimno, yinc =
      match pdims with
      | (pageno', w, h) :: rest when pageno' = pageno ->
          let ips = calcips h in
          let yinc = if conf.presentation then ips else 0 in
          (w, h, ips), rest, pdimno + 1, yinc
      | _ ->
          prev, pdims, pdimno, 0
    in
    let dy = dy + yinc in
    let py = py + yinc in
    if pageno = state.pagecount || cacheleft = 0 || dy >= sh
    then
      accu
    else
      let vy = y + dy in
      if py + h <= vy - yinc
      then
        let py = py + h + ips in
        let dy = max 0 (py - y) in
        f ~pageno:(pageno+1)
          ~pdimno
          ~prev:curr
          ~py
          ~dy
          ~pdims:rest
          ~cacheleft
          ~accu
      else
        let pagey = vy - py in
        let pagevh = h - pagey in
        let pagevh = min (sh - dy) pagevh in
        let off = if yinc > 0 then py - vy else 0
        in
        let py = py + h + ips in
        let e =
          { pageno = pageno
          ; pagedimno = pdimno
          ; pagew = w
          ; pageh = h
          ; pagedispy = dy + off
          ; pagey = pagey + off
          ; pagevh = pagevh - off
          }
        in
        let accu = e :: accu in
        f ~pageno:(pageno+1)
          ~pdimno
          ~prev:curr
          ~py
          ~dy:(dy+pagevh+ips)
          ~pdims:rest
          ~cacheleft:(cacheleft-1)
          ~accu
  in
  if state.invalidated = 0
  then (
    let accu =
      f
        ~pageno:0
        ~pdimno:~-1
        ~prev:(0,0,0)
        ~py:0
        ~dy:0
        ~pdims:state.pdims
        ~cacheleft:(cblen state.pagecache)
        ~accu:[]
    in
    List.rev accu
  )
  else
    []
;;

let clamp incr =
  let y = state.y + incr in
  let y = max 0 y in
  let y = min y (state.maxy - (if conf.maxhfit then state.h else 0)) in
  y;
;;

let getopaque pageno =
  try Some (Hashtbl.find state.pagemap (pageno + 1, state.w, conf.angle))
  with Not_found -> None
;;

let cache pageno opaque =
  Hashtbl.replace state.pagemap (pageno + 1, state.w, conf.angle) opaque
;;

let validopaque opaque = String.length opaque > 0;;

let render l =
  match getopaque l.pageno with
  | None when not state.rendering ->
      state.rendering <- true;
      cache l.pageno "";
      wcmd "render" [`i (l.pageno + 1)
                    ;`i l.pagedimno
                    ;`i l.pagew
                    ;`i l.pageh];

  | _ -> ()
;;

let loadlayout layout =
  let rec f all = function
    | l :: ls ->
        begin match getopaque l.pageno with
        | None -> render l; f false ls
        | Some opaque -> f (all && validopaque opaque) ls
        end
    | [] -> all
  in
  f (layout <> []) layout;
;;

let preload () =
  if conf.preload
  then
    let evictedvisible =
      let evictedopaque = cbpeekw state.pagecache in
      List.exists (fun l ->
        match getopaque l.pageno with
        | Some opaque when validopaque opaque ->
            evictedopaque = opaque
        | otherwise -> false
      ) state.layout
    in
    if not evictedvisible
    then
      let rely = yratio state.y in
      let presentation = conf.presentation in
      let interpagespace = conf.interpagespace in
      let maxy = state.maxy in
      conf.presentation <- false;
      conf.interpagespace <- 0;
      state.maxy <- calcheight ();
      let y = truncate (float state.maxy *. rely) in
      let y = if y < state.h then 0 else y - state.h in
      let pages = layout y (state.h*3) in
      List.iter render pages;
      conf.presentation <- presentation;
      conf.interpagespace <- interpagespace;
      state.maxy <- maxy;
;;

let gotoy y =
  let y = max 0 y in
  let y = min state.maxy y in
  let pages = layout y state.h in
  let ready = loadlayout pages in
  state.ty <- yratio y;
  if conf.showall
  then (
    if ready
    then (
      state.layout <- pages;
      state.y <- y;
      Glut.setCursor Glut.CURSOR_INHERIT;
      Glut.postRedisplay ();
    )
    else (
      Glut.setCursor Glut.CURSOR_WAIT;
    );
  )
  else (
    state.layout <- pages;
    state.y <- y;
    Glut.postRedisplay ();
  );
  preload ();
;;

let gotoy_and_clear_text y =
  gotoy y;
  if not conf.verbose then state.text <- "";
;;

let addnav () =
  cbput state.hists.nav (yratio state.y);
  cbrfollowlen state.hists.nav;
;;

let getnav () =
  let y = cbget state.hists.nav ~-1 in
  truncate (y *. float state.maxy)
;;

let gotopage n top =
  let y, h = getpageyh n in
  addnav ();
  gotoy_and_clear_text (y + (truncate (top *. float h)));
;;

let gotopage1 n top =
  let y = getpagey n in
  addnav ();
  gotoy_and_clear_text (y + top);
;;

let invalidate () =
  state.layout <- [];
  state.pdims <- [];
  state.rects <- [];
  state.rects1 <- [];
  state.invalidated <- state.invalidated + 1;
;;

let scalecolor c =
  let c = c *. state.colorscale in
  (c, c, c);
;;

let represent () =
  let y =
    match state.layout with
    | [] ->
        let rely = yratio state.y in
        state.maxy <- calcheight ();
        truncate (float state.maxy *. rely)

    | l :: _ ->
        state.maxy <- calcheight ();
        getpagey l.pageno
  in
  gotoy y
;;

let pagematrix () =
  GlMat.mode `projection;
  GlMat.load_identity ();
  GlMat.rotate ~x:1.0 ~angle:180.0 ();
  GlMat.translate ~x:~-.1.0 ~y:~-.1.0 ();
  GlMat.scale3 (2.0 /. float state.w, 2.0 /. float state.h, 1.0);
;;

let winmatrix () =
  GlMat.mode `projection;
  GlMat.load_identity ();
  GlMat.rotate ~x:1.0 ~angle:180.0 ();
  GlMat.translate ~x:~-.1.0 ~y:~-.1.0 ();
  GlMat.scale3 (2.0 /. float state.winw, 2.0 /. float state.h, 1.0);
;;

let reshape ~w ~h =
  state.winw <- w;
  let w = truncate (float w *. conf.zoom) - conf.scrollw in
  state.w <- w;
  state.h <- h;
  GlMat.mode `modelview;
  GlMat.load_identity ();
  GlClear.color (scalecolor 1.0);
  GlClear.clear [`color];

  invalidate ();
  wcmd "geometry" [`i w; `i h];
;;

let showtext c s =
  GlDraw.color (0.0, 0.0, 0.0);
  GlDraw.rect
    (0.0, float (state.h - 18))
    (float (state.winw - conf.scrollw - 1), float state.h)
  ;
  let font = Glut.BITMAP_8_BY_13 in
  GlDraw.color (1.0, 1.0, 1.0);
  GlPix.raster_pos ~x:0.0 ~y:(float (state.h - 5)) ();
  Glut.bitmapCharacter ~font ~c:(Char.code c);
  String.iter (fun c -> Glut.bitmapCharacter ~font ~c:(Char.code c)) s;
;;

let enttext () =
  let len = String.length state.text in
  match state.textentry with
  | None ->
      if len > 0 then showtext ' ' state.text

  | Some (c, text, _, _, _) ->
      let s =
        if len > 0
        then
          text ^ " [" ^ state.text ^ "]"
        else
          text
      in
      showtext c s;
;;

let showtext c s =
  if true
  then (
    state.text <- Printf.sprintf "%c%s" c s;
    Glut.postRedisplay ();
  )
  else (
    showtext c s;
    Glut.swapBuffers ();
  )
;;

let act cmd =
  match cmd.[0] with
  | 'c' ->
      state.pdims <- [];

  | 'D' ->
      state.rects <- state.rects1;
      Glut.postRedisplay ()

  | 'C' ->
      let n = Scanf.sscanf cmd "C %d" (fun n -> n) in
      state.pagecount <- n;
      state.invalidated <- state.invalidated - 1;
      if state.invalidated = 0
      then represent ()

  | 't' ->
      let s = Scanf.sscanf cmd "t %n"
        (fun n -> String.sub cmd n (String.length cmd - n))
      in
      Glut.setWindowTitle s

  | 'T' ->
      let s = Scanf.sscanf cmd "T %n"
        (fun n -> String.sub cmd n (String.length cmd - n))
      in
      if state.textentry = None
      then (
        state.text <- s;
        showtext ' ' s;
      )
      else (
        state.text <- s;
        Glut.postRedisplay ();
      )

  | 'V' ->
      if conf.verbose
      then
        let s = Scanf.sscanf cmd "V %n"
          (fun n -> String.sub cmd n (String.length cmd - n))
        in
        state.text <- s;
        showtext ' ' s;

  | 'F' ->
      let pageno, c, x0, y0, x1, y1, x2, y2, x3, y3 =
        Scanf.sscanf cmd "F %d %d %f %f %f %f %f %f %f %f"
          (fun p c x0 y0 x1 y1 x2 y2 x3 y3 ->
            (p, c, x0, y0, x1, y1, x2, y2, x3, y3))
      in
      let y = (getpagey pageno) + truncate y0 in
      addnav ();
      gotoy y;
      state.rects1 <- [pageno, c, (x0, y0, x1, y1, x2, y2, x3, y3)]

  | 'R' ->
      let pageno, c, x0, y0, x1, y1, x2, y2, x3, y3 =
        Scanf.sscanf cmd "R %d %d %f %f %f %f %f %f %f %f"
          (fun p c x0 y0 x1 y1 x2 y2 x3 y3 ->
            (p, c, x0, y0, x1, y1, x2, y2, x3, y3))
      in
      state.rects1 <-
        (pageno, c, (x0, y0, x1, y1, x2, y2, x3, y3)) :: state.rects1

  | 'r' ->
      let n, w, h, r, p =
        Scanf.sscanf cmd "r %d %d %d %d %s"
          (fun n w h r p -> (n, w, h, r, p))
      in
      Hashtbl.replace state.pagemap (n, w, r) p;
      let opaque = cbpeekw state.pagecache in
      if validopaque opaque
      then (
        let k =
          Hashtbl.fold
            (fun k v a -> if v = opaque then k else a)
            state.pagemap (-1, -1, -1)
        in
        wcmd "free" [`s opaque];
        Hashtbl.remove state.pagemap k
      );
      cbput state.pagecache p;
      state.rendering <- false;
      if conf.showall
      then gotoy (truncate (ceil (state.ty *. float state.maxy)))
      else (
        let visible = List.exists (fun l -> l.pageno + 1 = n) state.layout in
        if visible
        then gotoy state.y
        else (ignore (loadlayout state.layout); preload ())
      )

  | 'l' ->
      let (n, w, h) as pdim =
        Scanf.sscanf cmd "l %d %d %d" (fun n w h -> n, w, h)
      in
      state.pdims <- pdim :: state.pdims

  | 'o' ->
      let (l, n, t, h, pos) =
        Scanf.sscanf cmd "o %d %d %d %d %n" (fun l n t h pos -> l, n, t, h, pos)
      in
      let s = String.sub cmd pos (String.length cmd - pos) in
      let s =
        let l = String.length s in
        let b = Buffer.create (String.length s) in
        let rec loop pc2 i =
          if i = l
          then ()
          else
            let pc2 =
              match s.[i] with
              | '\xa0' when pc2 -> Buffer.add_char b ' '; false
              | '\xc2' -> true
              | c ->
                  let c = if Char.code c land 0x80 = 0 then c else '?' in
                  Buffer.add_char b c;
                  false
            in
            loop pc2 (i+1)
        in
        loop false 0;
        Buffer.contents b
      in
      let outline = (s, l, n, float t /. float h) in
      let outlines =
        match state.outlines with
        | Olist outlines -> Olist (outline :: outlines)
        | Oarray _ -> Olist [outline]
        | Onarrow _ -> Olist [outline]
      in
      state.outlines <- outlines

  | _ ->
      log "unknown cmd `%S'" cmd
;;

let now = Unix.gettimeofday;;

let idle () =
  let rec loop delay =
    let r, _, _ = Unix.select [state.csock] [] [] delay in
    begin match r with
    | [] ->
        if conf.autoscroll
        then begin
          let y = state.y + conf.scrollincr in
          let y = if y >= state.maxy then 0 else y in
          gotoy y;
          state.text <- "";
        end;

    | _ ->
        let cmd = readcmd state.csock in
        act cmd;
        loop 0.0
    end;
  in loop 0.001
;;

let onhist cb = function
  | HCprev  -> cbget cb ~-1
  | HCnext  -> cbget cb 1
  | HCfirst -> cbget cb ~-(cb.rc)
  | HClast  -> cbget cb (cb.len - 1 - cb.rc)
;;

let search pattern forward =
  if String.length pattern > 0
  then
    let pn, py =
      match state.layout with
      | [] -> 0, 0
      | l :: _ ->
          l.pageno, (l.pagey + if forward then 0 else 0*l.pagevh)
    in
    let cmd =
      let b = makecmd "search"
        [`b conf.icase; `i pn; `i py; `i (if forward then 1 else 0)]
      in
      Buffer.add_char b ',';
      Buffer.add_string b pattern;
      Buffer.add_char b '\000';
      Buffer.contents b;
    in
    writecmd state.csock cmd;
;;

let intentry text key =
  let c = Char.unsafe_chr key in
  match c with
  | '0' .. '9' ->
      let s = "x" in s.[0] <- c;
      let text = text ^ s in
      TEcont text

  | _ ->
      state.text <- Printf.sprintf "invalid char (%d, `%c')" key c;
      TEcont text
;;

let addchar s c =
  let b = Buffer.create (String.length s + 1) in
  Buffer.add_string b s;
  Buffer.add_char b c;
  Buffer.contents b;
;;

let textentry text key =
  let c = Char.unsafe_chr key in
  match c with
  | _ when key >= 32 && key < 127 ->
      let text = addchar text c in
      TEcont text

  | _ ->
      log "unhandled key %d char `%c'" key (Char.unsafe_chr key);
      TEcont text
;;

let rotate angle =
  conf.angle <- angle;
  invalidate ();
  wcmd "rotate" [`i angle];
;;

let optentry text key =
  let btos b = if b then "on" else "off" in
  let c = Char.unsafe_chr key in
  match c with
  | 's' ->
      let ondone s =
        try conf.scrollincr <- int_of_string s with exc ->
          state.text <- Printf.sprintf "bad integer `%s': %s"
            s (Printexc.to_string exc)
      in
      TEswitch ('#', "", None, intentry, ondone)

  | 'R' ->
      let ondone s =
        match try
            Some (int_of_string s)
          with exc ->
            state.text <- Printf.sprintf "bad integer `%s': %s"
              s (Printexc.to_string exc);
            None
        with
        | Some angle -> rotate angle
        | None -> ()
      in
      TEswitch ('^', "", None, intentry, ondone)

  | 'i' ->
      conf.icase <- not conf.icase;
      TEdone ("case insensitive search " ^ (btos conf.icase))

  | 'p' ->
      conf.preload <- not conf.preload;
      gotoy state.y;
      TEdone ("preload " ^ (btos conf.preload))

  | 'v' ->
      conf.verbose <- not conf.verbose;
      TEdone ("verbose " ^ (btos conf.verbose))

  | 'h' ->
      conf.maxhfit <- not conf.maxhfit;
      state.maxy <- state.maxy + (if conf.maxhfit then -state.h else state.h);
      TEdone ("maxhfit " ^ (btos conf.maxhfit))

  | 'c' ->
      conf.crophack <- not conf.crophack;
      TEdone ("crophack " ^ btos conf.crophack)

  | 'a' ->
      conf.showall <- not conf.showall;
      TEdone ("showall " ^ btos conf.showall)

  | 'f' ->
      conf.underinfo <- not conf.underinfo;
      TEdone ("underinfo " ^ btos conf.underinfo)

  | 'S' ->
      let ondone s =
        try
          conf.interpagespace <- int_of_string s;
          let rely = yratio state.y in
          state.maxy <- calcheight ();
          gotoy (truncate (float state.maxy *. rely));
        with exc ->
          state.text <- Printf.sprintf "bad integer `%s': %s"
            s (Printexc.to_string exc)
      in
      TEswitch ('%', "", None, intentry, ondone)

  | _ ->
      state.text <- Printf.sprintf "bad option %d `%c'" key c;
      TEstop
;;

let maxoutlinerows () = (state.h - 31) / 16;;

let enterselector allowdel outlines errmsg =
  if Array.length outlines = 0
  then (
    showtext ' ' errmsg;
  )
  else (
    state.text <- "";
    Glut.setCursor Glut.CURSOR_INHERIT;
    let pageno =
      match state.layout with
      | [] -> -1
      | {pageno=pageno} :: rest -> pageno
    in
    let active =
      let rec loop n =
        if n = Array.length outlines
        then 0
        else
          let (_, _, outlinepageno, _) = outlines.(n) in
          if outlinepageno >= pageno then n else loop (n+1)
      in
      loop 0
    in
    state.outline <-
      Some (allowdel, active,
           max 0 ((active - maxoutlinerows () / 2)), outlines, "");
    Glut.postRedisplay ();
  )
;;

let enteroutlinemode () =
  let outlines =
    match state.outlines with
    | Oarray a -> a
    | Olist l ->
        let a = Array.of_list (List.rev l) in
        state.outlines <- Oarray a;
        a
    | Onarrow (a, b) -> a
  in
  enterselector false outlines "Document has no outline";
;;

let enterbookmarkmode () =
  let bookmarks = Array.of_list state.bookmarks in
  enterselector true bookmarks "Document has no bookmarks (yet)";
;;

let quickbookmark ?title () =
  match state.layout with
  | [] -> ()
  | l :: _ ->
      let title =
        match title with
        | None ->
            let sec = Unix.gettimeofday () in
            let tm = Unix.localtime sec in
            Printf.sprintf "Quick %d visited (%d/%d/%d %d:%d)"
              l.pageno
              tm.Unix.tm_mday
              tm.Unix.tm_mon
              (tm.Unix.tm_year + 1900)
              tm.Unix.tm_hour
              tm.Unix.tm_min
        | Some title -> title
      in
      state.bookmarks <-
        (title, 0, l.pageno, float l.pagey /. float l.pageh) :: state.bookmarks
;;

let doreshape w h =
  state.fullscreen <- None;
  Glut.reshapeWindow w h;
;;

let opendoc path password =
  invalidate ();
  state.path <- path;
  state.password <- password;
  Hashtbl.clear state.pagemap;

  writecmd state.csock ("open " ^ path ^ "\000" ^ password ^ "\000");
  Glut.setWindowTitle ("llpp " ^ Filename.basename path);
  wcmd "geometry" [`i state.w; `i state.h];
;;

let viewkeyboard ~key ~x ~y =
  let enttext te =
    state.textentry <- te;
    state.text <- "";
    enttext ();
    Glut.postRedisplay ()
  in
  match state.textentry with
  | None ->
      let c = Char.chr key in
      begin match c with
      | '\027' | 'q' ->
          exit 0

      | '\008' ->
          let y = getnav () in
          gotoy_and_clear_text y

      | 'o' ->
          enteroutlinemode ()

      | 'u' ->
          state.rects <- [];
          state.text <- "";
          Glut.postRedisplay ()

      | '/' | '?' ->
          let ondone isforw s =
            cbput state.hists.pat s;
            cbrfollowlen state.hists.pat;
            state.searchpattern <- s;
            search s isforw
          in
          enttext (Some (c, "", Some (onhist state.hists.pat),
                        textentry, ondone (c ='/')))

      | '+' when Glut.getModifiers () land Glut.active_ctrl != 0 ->
          conf.zoom <- min 2.2 (conf.zoom +. 0.1);
          state.text <- Printf.sprintf "zoom is %3.1f%%" (100.0*.conf.zoom);
          reshape state.winw state.h

      | '+' ->
          let ondone s =
            let n =
              try int_of_string s with exc ->
                state.text <- Printf.sprintf "bad integer `%s': %s"
                  s (Printexc.to_string exc);
                max_int
            in
            if n != max_int
            then (
              conf.pagebias <- n;
              state.text <- "page bias is now " ^ string_of_int n;
            )
          in
          enttext (Some ('+', "", None, intentry, ondone))

      | '-' when Glut.getModifiers () land Glut.active_ctrl != 0 ->
          conf.zoom <- max 0.1 (conf.zoom -. 0.1);
          if conf.zoom <= 1.0 then state.x <- 0;
          state.text <- Printf.sprintf "zoom is %3.1f%%" (100.0*.conf.zoom);
          reshape state.winw state.h;

      | '-' ->
          let ondone msg =
            state.text <- msg;
          in
          enttext (Some ('-', "", None, optentry, ondone))

      | '0' when (Glut.getModifiers () land Glut.active_ctrl != 0) ->
          state.x <- 0;
          conf.zoom <- 1.0;
          state.text <- "zoom is 100%";
          reshape state.winw state.h

      | '1' when (Glut.getModifiers () land Glut.active_ctrl != 0) ->
          let n =
            let rec find n maxh nformaxh = function
              | (_, _, h) :: rest ->
                  if h > maxh
                  then find (n+1) h n rest
                  else find (n+1) maxh nformaxh rest
              | [] -> nformaxh
            in
            find 0 0 0 state.pdims
          in

          let rect = getpdimrect n in
          let pw = rect.(1) -. rect.(0) in
          let ph = rect.(3) -. rect.(2) in

          let num = (float state.h *. pw) +. (ph *. float conf.scrollw) in
          let den = ph *. float state.winw in
          let zoom = num /. den in

          if zoom < 1.0
          then (
            conf.zoom <- zoom;
            state.x <- 0;
            state.text <- Printf.sprintf "zoom is %3.1f%%" (100.0*.conf.zoom);
            reshape state.winw state.h;
          )

      | '0' .. '9' ->
          let ondone s =
            let n =
              try int_of_string s with exc ->
                state.text <- Printf.sprintf "bad integer `%s': %s"
                  s (Printexc.to_string exc);
                -1
            in
            if n >= 0
            then (
              addnav ();
              cbput state.hists.pag (string_of_int n);
              cbrfollowlen state.hists.pag;
              gotoy_and_clear_text (getpagey (n + conf.pagebias - 1))
            )
          in
          let pageentry text key =
            match Char.unsafe_chr key with
            | 'g' -> TEdone text
            | _ -> intentry text key
          in
          let text = "x" in text.[0] <- c;
          enttext (Some (':', text, Some (onhist state.hists.pag),
                        pageentry, ondone))

      | 'b' ->
          conf.scrollw <- if conf.scrollw > 0 then 0 else 7;
          reshape state.winw state.h;

      | 'l' ->
          conf.hlinks <- not conf.hlinks;
          state.text <- "highlightlinks " ^ if conf.hlinks then "on" else "off";
          Glut.postRedisplay ()

      | 'a' ->
          conf.autoscroll <- not conf.autoscroll

      | 'P' ->
          conf.presentation <- not conf.presentation;
          showtext ' ' ("presentation mode " ^
                       if conf.presentation then "on" else "off");
          represent ()

      | 'f' ->
          begin match state.fullscreen with
          | None ->
              state.fullscreen <- Some (state.winw, state.h);
              Glut.fullScreen ()
          | Some (w, h) ->
              state.fullscreen <- None;
              doreshape w h
          end

      | 'g' ->
          gotoy_and_clear_text 0

      | 'n' ->
          search state.searchpattern true

      | 'p' | 'N' ->
          search state.searchpattern false

      | 't' ->
          begin match state.layout with
          | [] -> ()
          | l :: _ ->
              gotoy_and_clear_text (getpagey l.pageno)
          end

      | ' ' ->
          begin match List.rev state.layout with
          | [] -> ()
          | l :: _ ->
              let pageno = min (l.pageno+1) (state.pagecount-1) in
              gotoy_and_clear_text (getpagey pageno)
          end

      | '\127' ->
          begin match state.layout with
          | [] -> ()
          | l :: _ ->
              let pageno = max 0 (l.pageno-1) in
              gotoy_and_clear_text (getpagey pageno)
          end

      | '=' ->
          let f (fn, ln) l =
            if fn = -1 then l.pageno, l.pageno else fn, l.pageno
          in
          let fn, ln = List.fold_left f (-1, -1) state.layout in
          let s =
            let maxy = state.maxy - (if conf.maxhfit then state.h else 0) in
            let percent =
              if maxy <= 0
              then 100.
              else (100. *. (float state.y /. float maxy)) in
            if fn = ln
            then
              Printf.sprintf "Page %d of %d %.2f%%"
                (fn+1) state.pagecount percent
            else
              Printf.sprintf
                "Pages %d-%d of %d %.2f%%"
                (fn+1) (ln+1) state.pagecount percent
          in
          showtext ' ' s;

      | 'w' ->
          begin match state.layout with
          | [] -> ()
          | l :: _ ->
              doreshape (l.pagew + conf.scrollw) l.pageh;
              Glut.postRedisplay ();
          end

      | '\'' ->
          enterbookmarkmode ()

      | 'm' ->
          let ondone s =
            match state.layout with
            | l :: _ ->
                state.bookmarks <-
                  (s, 0, l.pageno, float l.pagey /. float l.pageh)
                :: state.bookmarks
            | _ -> ()
          in
          enttext (Some ('~', "", None, textentry, ondone))

      | '~' ->
          quickbookmark ();
          showtext ' ' "Quick bookmark added";

      | 'z' ->
          begin match state.layout with
          | l :: _ ->
              let rect = getpdimrect l.pagedimno in
              let w, h =
                if conf.crophack
                then
                  (truncate (1.8 *. (rect.(1) -. rect.(0))),
                  truncate (1.2 *. (rect.(3) -. rect.(0))))
                else
                  (truncate (rect.(1) -. rect.(0)),
                  truncate (rect.(3) -. rect.(0)))
              in
              doreshape (w + conf.scrollw) (h + conf.interpagespace);
              Glut.postRedisplay ();

          | [] -> ()
          end

      | '<' | '>' ->
          rotate (conf.angle + (if c = '>' then 30 else -30));

      | '[' | ']' ->
          state.colorscale <-
            max 0.0
            (min (state.colorscale +. (if c = ']' then 0.1 else -0.1)) 1.0);
          Glut.postRedisplay ()

      | 'k' -> gotoy (clamp (-conf.scrollincr))
      | 'j' -> gotoy (clamp conf.scrollincr)

      | 'r' -> opendoc state.path state.password

      | _ ->
          vlog "huh? %d %c" key (Char.chr key);
      end

  | Some (c, text, onhist, onkey, ondone) when key = 8 ->
      let len = String.length text in
      if len = 0
      then (
        state.textentry <- None;
        Glut.postRedisplay ();
      )
      else (
        let s = String.sub text 0 (len - 1) in
        enttext (Some (c, s, onhist, onkey, ondone))
      )

  | Some (c, text, onhist, onkey, ondone) ->
      begin match Char.unsafe_chr key with
      | '\r' | '\n' ->
          ondone text;
          state.textentry <- None;
          Glut.postRedisplay ()

      | '\027' ->
          state.textentry <- None;
          Glut.postRedisplay ()

      | _ ->
          begin match onkey text key with
          | TEdone text ->
              state.textentry <- None;
              ondone text;
              Glut.postRedisplay ()

          | TEcont text ->
              enttext (Some (c, text, onhist, onkey, ondone));

          | TEstop ->
              state.textentry <- None;
              Glut.postRedisplay ()

          | TEswitch te ->
              state.textentry <- Some te;
              Glut.postRedisplay ()
          end;
      end;
;;

let narrow outlines pattern =
  let reopt = try Some (Str.regexp_case_fold pattern) with _ -> None in
  match reopt with
  | None -> None
  | Some re ->
      let rec fold accu n =
        if n = -1
        then accu
        else
          let (s, _, _, _) as o = outlines.(n) in
          let accu =
            if (try ignore (Str.search_forward re s 0); true
              with Not_found -> false)
            then (o :: accu)
            else accu
          in
          fold accu (n-1)
      in
      let matched = fold [] (Array.length outlines - 1) in
      if matched = [] then None else Some (Array.of_list matched)
;;

let outlinekeyboard ~key ~x ~y (allowdel, active, first, outlines, qsearch) =
  let search active pattern incr =
    let dosearch re =
      let rec loop n =
        if n = Array.length outlines || n = -1
        then None
        else
          let (s, _, _, _) = outlines.(n) in
          if
            (try ignore (Str.search_forward re s 0); true
              with Not_found -> false)
          then Some n
          else loop (n + incr)
      in
      loop active
    in
    try
      let re = Str.regexp_case_fold pattern in
      dosearch re
    with Failure s ->
      state.text <- s;
      None
  in
  let firstof active = max 0 (active - maxoutlinerows () / 2) in
  match key with
  | 27 ->
      if String.length qsearch = 0
      then (
        state.text <- "";
        state.outline <- None;
        Glut.postRedisplay ();
      )
      else (
        state.text <- "";
        state.outline <- Some (allowdel, active, first, outlines, "");
        Glut.postRedisplay ();
      )

  | 18 | 19 ->
      let incr = if key = 18 then -1 else 1 in
      let active, first =
        match search (active + incr) qsearch incr with
        | None ->
            state.text <- qsearch ^ " [not found]";
            active, first
        | Some active ->
            state.text <- qsearch;
            active, firstof active
      in
      state.outline <- Some (allowdel, active, first, outlines, qsearch);
      Glut.postRedisplay ();

  | 8 ->
      let len = String.length qsearch in
      if len = 0
      then ()
      else (
        if len = 1
        then (
          state.text <- "";
          state.outline <- Some (allowdel, active, first, outlines, "");
        )
        else
          let qsearch = String.sub qsearch 0 (len - 1) in
          let active, first =
            match search active qsearch ~-1 with
            | None ->
                state.text <- qsearch ^ " [not found]";
                active, first
            | Some active ->
                state.text <- qsearch;
                active, firstof active
          in
          state.outline <- Some (allowdel, active, first, outlines, qsearch);
      );
      Glut.postRedisplay ()

  | 13 ->
      if active < Array.length outlines
      then (
        let (_, _, n, t) = outlines.(active) in
        gotopage n t;
      );
      state.text <- "";
      if allowdel then state.bookmarks <- Array.to_list outlines;
      state.outline <- None;
      Glut.postRedisplay ();

  | _ when key >= 32 && key < 127 ->
      let pattern = addchar qsearch (Char.chr key) in
      let active, first =
        match search active pattern 1 with
        | None ->
            state.text <- pattern ^ " [not found]";
            active, first
        | Some active ->
            state.text <- pattern;
            active, firstof active
      in
      state.outline <- Some (allowdel, active, first, outlines, pattern);
      Glut.postRedisplay ()

  | 14 when not allowdel ->
      let optoutlines = narrow outlines qsearch in
      begin match optoutlines with
      | None -> state.text <- "can't narrow"
      | Some outlines ->
          state.outline <- Some (allowdel, 0, 0, outlines, qsearch);
          match state.outlines with
          | Olist l -> ()
          | Oarray a -> state.outlines <- Onarrow (outlines, a)
          | Onarrow (a, b) -> state.outlines <- Onarrow (outlines, b)
      end;
      Glut.postRedisplay ()

  | 21 when not allowdel ->
      let outline =
        match state.outlines with
        | Oarray a -> a
        | Olist l ->
            let a = Array.of_list (List.rev l) in
            state.outlines <- Oarray a;
            a
        | Onarrow (a, b) ->
            state.outlines <- Oarray b;
            b
      in
      state.outline <- Some (allowdel, 0, 0, outline, qsearch);
      Glut.postRedisplay ()

  | 12 ->
      state.outline <-
        Some (allowdel, active, firstof active, outlines, qsearch);
      Glut.postRedisplay ()

  | 127 when allowdel ->
      let len = Array.length outlines - 1 in
      if len = 0
      then (
        state.outline <- None;
        state.bookmarks <- [];
      )
      else (
        let bookmarks = Array.init len
          (fun i ->
            let i = if i >= active then i + 1 else i in
            outlines.(i)
          )
        in
        state.outline <-
          Some (allowdel,
               min active (len-1),
               min first (len-1),
               bookmarks, qsearch)
        ;
      );
      Glut.postRedisplay ()

  | _ -> log "unknown key %d" key
;;

let keyboard ~key ~x ~y =
  if key = 7
  then
    wcmd "interrupt" []
  else
    match state.outline with
    | None -> viewkeyboard ~key ~x ~y
    | Some outline -> outlinekeyboard ~key ~x ~y outline
;;

let special ~key ~x ~y =
  match state.outline with
  | None ->
      begin match state.textentry with
      | None ->
          let y =
            match key with
            | Glut.KEY_F3        -> search state.searchpattern true; state.y
            | Glut.KEY_UP        -> clamp (-conf.scrollincr)
            | Glut.KEY_DOWN      -> clamp conf.scrollincr
            | Glut.KEY_PAGE_UP   ->
                if Glut.getModifiers () land Glut.active_ctrl != 0
                then
                  match state.layout with
                  | [] -> state.y
                  | l :: _ -> state.y - l.pagey
                else
                  clamp (-state.h)
            | Glut.KEY_PAGE_DOWN ->
                if Glut.getModifiers () land Glut.active_ctrl != 0
                then
                  match List.rev state.layout with
                  | [] -> state.y
                  | l :: _ -> getpagey l.pageno
                else
                  clamp state.h
            | Glut.KEY_HOME -> addnav (); 0
            | Glut.KEY_END ->
                addnav ();
                state.maxy - (if conf.maxhfit then state.h else 0)

            | Glut.KEY_RIGHT when conf.zoom > 1.0 ->
                state.x <- state.x - 10;
                state.y
            | Glut.KEY_LEFT when conf.zoom > 1.0  ->
                state.x <- state.x + 10;
                state.y

            | _ -> state.y
          in
          gotoy_and_clear_text y

      | Some (c, s, Some onhist, onkey, ondone) ->
          let s =
            match key with
            | Glut.KEY_UP    -> onhist HCprev
            | Glut.KEY_DOWN  -> onhist HCnext
            | Glut.KEY_HOME  -> onhist HCfirst
            | Glut.KEY_END   -> onhist HClast
            | _ -> state.text
          in
          state.textentry <- Some (c, s, Some onhist, onkey, ondone);
          Glut.postRedisplay ()

      | _ -> ()
      end

  | Some (allowdel, active, first, outlines, qsearch) ->
      let maxrows = maxoutlinerows () in
      let navigate incr =
        let active = active + incr in
        let active = max 0 (min active (Array.length outlines - 1)) in
        let first =
          if active > first
          then
            let rows = active - first in
            if rows > maxrows then active - maxrows else first
          else active
        in
        state.outline <- Some (allowdel, active, first, outlines, qsearch);
        Glut.postRedisplay ()
      in
      match key with
      | Glut.KEY_UP        -> navigate ~-1
      | Glut.KEY_DOWN      -> navigate   1
      | Glut.KEY_PAGE_UP   -> navigate ~-maxrows
      | Glut.KEY_PAGE_DOWN -> navigate   maxrows

      | Glut.KEY_HOME ->
          state.outline <- Some (allowdel, 0, 0, outlines, qsearch);
          Glut.postRedisplay ()

      | Glut.KEY_END ->
          let active = Array.length outlines - 1 in
          let first = max 0 (active - maxrows) in
          state.outline <- Some (allowdel, active, first, outlines, qsearch);
          Glut.postRedisplay ()

      | _ -> ()
;;

let drawplaceholder l =
  GlDraw.color (scalecolor 1.0);
  GlDraw.rect
    (0.0, float l.pagedispy)
    (float l.pagew, float (l.pagedispy + l.pagevh))
  ;
  let x = 0.0
  and y = float (l.pagedispy + 13) in
  let font = Glut.BITMAP_8_BY_13 in
  GlDraw.color (0.0, 0.0, 0.0);
  GlPix.raster_pos ~x ~y ();
  String.iter (fun c -> Glut.bitmapCharacter ~font ~c:(Char.code c))
    ("Loading " ^ string_of_int (l.pageno + 1));
;;

let now () = Unix.gettimeofday ();;

let drawpage i l =
  begin match getopaque l.pageno with
  | Some opaque when validopaque opaque ->
      if state.textentry = None
      then GlDraw.color (scalecolor 1.0)
      else GlDraw.color (scalecolor 0.4);
      let a = now () in
      draw (l.pagedispy, l.pagew, l.pagevh, l.pagey, conf.hlinks)
        opaque;
      let b = now () in
      let d = b-.a in
      vlog "draw %d %f sec" l.pageno d;

  | _ ->
      drawplaceholder l;
  end;
  l.pagedispy + l.pagevh;
;;

let scrollph y =
  let maxy = state.maxy - (if conf.maxhfit then state.h else 0) in
  let sh = (float (maxy + state.h) /. float state.h)  in
  let sh = float state.h /. sh in
  let sh = max sh (float conf.scrollh) in

  let percent =
    if state.y = state.maxy
    then 1.0
    else float y /. float maxy
  in
  let position = (float state.h -. sh) *. percent in

  let position =
    if position +. sh > float state.h
    then float state.h -. sh
    else position
  in
  position, sh;
;;

let scrollindicator () =
  GlDraw.color (0.64 , 0.64, 0.64);
  GlDraw.rect
    (float (state.winw - conf.scrollw), 0.)
    (float state.winw, float state.h)
  ;
  GlDraw.color (0.0, 0.0, 0.0);

  let position, sh = scrollph state.y in
  GlDraw.rect
    (float (state.winw - conf.scrollw), position)
    (float state.winw, position +. sh)
  ;
;;

let showsel margin =
  match state.mstate with
  | Mnone | Mscroll _ | Mpan _ ->
      ()

  | Msel ((x0, y0), (x1, y1)) ->
      let rec loop = function
        | l :: ls ->
            if (y0 >= l.pagedispy && y0 <= (l.pagedispy + l.pagevh))
              || ((y1 >= l.pagedispy && y1 <= (l.pagedispy + l.pagevh)))
            then
              match getopaque l.pageno with
              | Some opaque when validopaque opaque ->
                  let oy = -l.pagey + l.pagedispy in
                  seltext opaque
                    (x0 - margin - state.x, y0,
                    x1 - margin - state.x, y1) oy;
                  ()
              | _ -> ()
            else loop ls
        | [] -> ()
      in
      loop state.layout
;;

let showrects () =
  let panx = float state.x in
  Gl.enable `blend;
  GlDraw.color (0.0, 0.0, 1.0) ~alpha:0.5;
  GlFunc.blend_func `src_alpha `one_minus_src_alpha;
  List.iter
    (fun (pageno, c, (x0, y0, x1, y1, x2, y2, x3, y3)) ->
      List.iter (fun l ->
        if l.pageno = pageno
        then (
          let d = float (l.pagedispy - l.pagey) in
          GlDraw.color (0.0, 0.0, 1.0 /. float c) ~alpha:0.5;
          GlDraw.begins `quads;
          (
            GlDraw.vertex2 (x0+.panx, y0+.d);
            GlDraw.vertex2 (x1+.panx, y1+.d);
            GlDraw.vertex2 (x2+.panx, y2+.d);
            GlDraw.vertex2 (x3+.panx, y3+.d);
          );
          GlDraw.ends ();
        )
      ) state.layout
    ) state.rects
  ;
  Gl.disable `blend;
;;

let showoutline = function
  | None -> ()
  | Some (allowdel, active, first, outlines, qsearch) ->
      Gl.enable `blend;
      GlFunc.blend_func `src_alpha `one_minus_src_alpha;
      GlDraw.color (0., 0., 0.) ~alpha:0.85;
      GlDraw.rect (0., 0.) (float state.w, float state.h);
      Gl.disable `blend;

      GlDraw.color (1., 1., 1.);
      let font = Glut.BITMAP_9_BY_15 in
      let draw_string x y s =
        GlPix.raster_pos ~x ~y ();
        String.iter (fun c -> Glut.bitmapCharacter ~font ~c:(Char.code c)) s
      in
      let rec loop row =
        if row = Array.length outlines || (row - first) * 16 > state.h
        then ()
        else (
          let (s, l, _, _) = outlines.(row) in
          let y = (row - first) * 16 in
          let x = 5 + 15*l in
          if row = active
          then (
            Gl.enable `blend;
            GlDraw.polygon_mode `both `line;
            GlFunc.blend_func `src_alpha `one_minus_src_alpha;
            GlDraw.color (1., 1., 1.) ~alpha:0.9;
            GlDraw.rect (0., float (y + 1))
              (float (state.w - 1), float (y + 18));
            GlDraw.polygon_mode `both `fill;
            Gl.disable `blend;
            GlDraw.color (1., 1., 1.);
          );
          draw_string (float x) (float (y + 16)) s;
          loop (row+1)
        )
      in
      loop first
;;

let display () =
  let margin = (state.winw - (state.w + conf.scrollw)) / 2 in
  GlDraw.viewport margin 0 state.w state.h;
  pagematrix ();
  GlClear.color (scalecolor 0.5);
  GlClear.clear [`color];
  if state.x != 0
  then (
    let x = float state.x in
    GlMat.translate ~x ();
  );
  if conf.zoom > 1.0
  then (
    Gl.enable `scissor_test;
    GlMisc.scissor 0 0 (state.winw - conf.scrollw) state.h;
  );
  let _lasty = List.fold_left drawpage 0 (state.layout) in
  if conf.zoom > 1.0
  then
    Gl.disable `scissor_test
  ;
  if state.x != 0
  then (
    let x = -.float state.x in
    GlMat.translate ~x ();
  );
  showrects ();
  showsel margin;
  GlDraw.viewport 0 0 state.winw state.h;
  winmatrix ();
  scrollindicator ();
  showoutline state.outline;
  enttext ();
  Glut.swapBuffers ();
;;

let getunder x y =
  let margin = (state.winw - (state.w + conf.scrollw)) / 2 in
  let x = x - margin - state.x in
  let rec f = function
    | l :: rest ->
        begin match getopaque l.pageno with
        | Some opaque when validopaque opaque ->
            let y = y - l.pagedispy in
            if y > 0
            then
              let y = l.pagey + y in
              match whatsunder opaque x y with
              | Unone -> f rest
              | under -> under
            else
              f rest
        | _ ->
            f rest
        end
    | [] -> Unone
  in
  f state.layout
;;

let mouse ~button ~bstate ~x ~y =
  match button with
  | Glut.OTHER_BUTTON n when (n == 3 || n == 4) && bstate = Glut.UP ->
      let incr =
        if n = 3
        then
          -conf.scrollincr
        else
          conf.scrollincr
      in
      let incr = incr * 2 in
      let y = clamp incr in
      gotoy_and_clear_text y

  | Glut.LEFT_BUTTON when state.outline = None
      && Glut.getModifiers () land Glut.active_ctrl != 0 ->
      if bstate = Glut.DOWN
      then (
        Glut.setCursor Glut.CURSOR_CROSSHAIR;
        state.mstate <- Mpan (x, y)
      )
      else
        state.mstate <- Mnone

  | Glut.LEFT_BUTTON when state.outline = None
      && x > state.w ->
      if bstate = Glut.DOWN
      then
        let position, sh = scrollph state.y in
        if y > truncate position && y < truncate (position +. sh)
        then
          state.mstate <- Mscroll
        else
          let percent = float y /. float state.h in
          let desty = truncate (float (state.maxy - state.h) *. percent) in
          gotoy desty;
          state.mstate <- Mscroll
      else
        state.mstate <- Mnone

  | Glut.LEFT_BUTTON when state.outline = None ->
      let dest = if bstate = Glut.DOWN then getunder x y else Unone in
      begin match dest with
      | Ulinkgoto (pageno, top) ->
          if pageno >= 0
          then
            gotopage1 pageno top

      | Ulinkuri s ->
          print_endline s

      | Unone when bstate = Glut.DOWN ->
          Glut.setCursor Glut.CURSOR_CROSSHAIR;
          state.mstate <- Mpan (x, y);

      | Unone | Utext _ ->
          if bstate = Glut.DOWN
          then (
            if conf.angle mod 360 = 0
            then (
              state.mstate <- Msel ((x, y), (x, y));
              Glut.postRedisplay ()
            )
          )
          else (
            match state.mstate with
            | Mnone  -> ()

            | Mscroll ->
                state.mstate <- Mnone

            | Mpan _ ->
                Glut.setCursor Glut.CURSOR_INHERIT;
                state.mstate <- Mnone

            | Msel ((x0, y0), (x1, y1)) ->
                let f l =
                  if (y0 >= l.pagedispy && y0 <= (l.pagedispy + l.pagevh))
                    || ((y1 >= l.pagedispy && y1 <= (l.pagedispy + l.pagevh)))
                  then
                      match getopaque l.pageno with
                      | Some opaque when validopaque opaque ->
                          copysel opaque
                      | _ -> ()
                in
                List.iter f state.layout;
                copysel "";             (* ugly *)
                Glut.setCursor Glut.CURSOR_INHERIT;
                state.mstate <- Mnone;
          )
      end

  | _ ->
      ()
;;
let mouse ~button ~state ~x ~y = mouse button state x y;;

let motion ~x ~y =
  if state.outline = None
  then
    match state.mstate with
    | Mnone -> ()

    | Mpan (x0, y0) ->
        let dx = x - x0
        and dy = y0 - y in
        state.mstate <- Mpan (x, y);
        if conf.zoom > 1.0 then state.x <- state.x + dx;
        let y = clamp dy in
        gotoy_and_clear_text y

    | Msel (a, _) ->
        state.mstate <- Msel (a, (x, y));
        Glut.postRedisplay ()

    | Mscroll ->
        let y = min state.h (max 0 y) in
        let percent = float y /. float state.h in
        let y = truncate (float (state.maxy - state.h) *. percent) in
        gotoy_and_clear_text y
;;

let pmotion ~x ~y =
  if state.outline = None
  then
    match state.mstate with
    | Mnone ->
        begin match getunder x y with
        | Unone -> Glut.setCursor Glut.CURSOR_INHERIT
        | Ulinkuri uri ->
            if conf.underinfo then showtext 'u' ("ri: " ^ uri);
            Glut.setCursor Glut.CURSOR_INFO
        | Ulinkgoto (page, y) ->
            if conf.underinfo then showtext 'p' ("age: " ^ string_of_int page);
            Glut.setCursor Glut.CURSOR_INFO
        | Utext s ->
            if conf.underinfo then showtext 'f' ("ont: " ^ s);
            Glut.setCursor Glut.CURSOR_TEXT
        end

    | Mpan _ | Msel _ | Mscroll ->
        ()
;;

let () =
  let statepath =
    let home =
      if Sys.os_type = "Win32"
      then
        try Sys.getenv "HOMEPATH" with Not_found -> ""
      else
        try Filename.concat (Sys.getenv "HOME") ".config" with Not_found -> ""
    in
    Filename.concat home "llpp"
  in
  let pstate =
    try
      let ic = open_in_bin statepath in
      let hash = input_value ic in
      close_in ic;
      hash
    with exn ->
      if false
      then
        prerr_endline ("Error loading state " ^ Printexc.to_string exn)
      ;
      Hashtbl.create 1
  in
  let savestate () =
    try
      let w, h =
        match state.fullscreen with
        | None -> state.winw, state.h
        | Some wh -> wh
      in
      Hashtbl.replace pstate state.path (state.bookmarks, w, h);
      let oc = open_out_bin statepath in
      output_value oc pstate
    with exn ->
      if false
      then
        prerr_endline ("Error saving state " ^ Printexc.to_string exn)
      ;
  in
  let setstate () =
    try
      let statebookmarks, statew, stateh = Hashtbl.find pstate state.path in
      state.w <- statew;
      state.h <- stateh;
      state.bookmarks <- statebookmarks;
    with Not_found -> ()
    | exn ->
      prerr_endline ("Error setting state " ^ Printexc.to_string exn)
  in

  Arg.parse
    ["-p", Arg.String (fun s -> state.password <- s) , "password"]
    (fun s -> state.path <- s)
    ("Usage: " ^ Sys.argv.(0) ^ " [options] some.pdf\noptions:")
  ;
  let name =
    if String.length state.path = 0
    then (prerr_endline "filename missing"; exit 1)
    else state.path
  in

  setstate ();
  let _ = Glut.init Sys.argv in
  let () = Glut.initDisplayMode ~depth:false ~double_buffer:true () in
  let () = Glut.initWindowSize state.w state.h in
  let _ = Glut.createWindow ("llpp " ^ Filename.basename name) in

  let csock, ssock =
    if Sys.os_type = "Unix"
    then
      Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0
    else
      let addr = Unix.ADDR_INET (Unix.inet_addr_loopback, 1337) in
      let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      Unix.setsockopt sock Unix.SO_REUSEADDR true;
      Unix.bind sock addr;
      Unix.listen sock 1;
      let csock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      Unix.connect csock addr;
      let ssock, _ = Unix.accept sock in
      Unix.close sock;
      let opts sock =
        Unix.setsockopt sock Unix.TCP_NODELAY true;
        Unix.setsockopt_optint sock Unix.SO_LINGER None;
      in
      opts ssock;
      opts csock;
      at_exit (fun () -> Unix.shutdown ssock Unix.SHUTDOWN_ALL);
      ssock, csock
  in

  let () = Glut.displayFunc display in
  let () = Glut.reshapeFunc reshape in
  let () = Glut.keyboardFunc keyboard in
  let () = Glut.specialFunc special in
  let () = Glut.idleFunc (Some idle) in
  let () = Glut.mouseFunc mouse in
  let () = Glut.motionFunc motion in
  let () = Glut.passiveMotionFunc pmotion in

  init ssock;
  state.csock <- csock;
  state.ssock <- ssock;
  state.text <- "Opening " ^ name;
  writecmd state.csock ("open " ^ state.path ^ "\000" ^ state.password ^ "\000");

  at_exit savestate;

  let rec handlelablglutbug () =
    try
      Glut.mainLoop ();
    with Glut.BadEnum "key in special_of_int" ->
      showtext '!' " LablGlut bug: special key not recognized";
      handlelablglutbug ()
  in
  handlelablglutbug ();
;;
