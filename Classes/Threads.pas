unit Threads;

interface

uses Windows, Forms;    

type
  TProcArguments = array of Pointer;

  { Callback procedure return value depend on the Caller type:
    * TSingleThread - it's thread's exit code,
    * TMMTimer - return anything greater than 0 to stop the timer. }
  TCallbackProc = function (Caller: TObject; const Arguments: TProcArguments): DWord;
  TObjectCallbackProc = function (Caller: TObject; const Arguments: TProcArguments): DWord of object;

  TProcSettings = record
    Caller: TObject;
    Args: TProcArguments;

    case IsObjectProc: Boolean of
    True:  (ObjectProc: TObjectCallbackProc);
    False: (Proc: TCallbackProc);
  end;

  TSingleThread = class
  protected
    FSettings: TProcSettings;
    FHandle: DWord;
    FThreadID: DWord;
    FTimeOut: DWord;
  public
    constructor Create; overload;
    constructor Create(Proc: TCallbackProc; const Arguments: TProcArguments = NIL;
      Suspended: Boolean = False); overload;
    constructor Create(ObjectProc: TObjectCallbackProc; const Arguments: TProcArguments = NIL;
      Suspended: Boolean = False); overload;
    destructor Destroy; override;

    property Handle: DWord read FHandle;
    function Running: Boolean;
    function HasFinished: Boolean;
    function ExitCode: DWord;
    function HasTimedOut: Boolean;

    procedure Run;
    procedure SetArguments(const Arguments: TProcArguments);
    procedure Kill(ExitCode: DWord = DWord(-1));
    procedure Wait;
    // in seconds. Has effect only before Wait is called.
    property TimeOut: DWord read FTimeOut write FTimeOut default 60;
  end;

  TMMTimer = class
  protected
    FSettings: TProcSettings;
    FHandle: DWord;
    FDelay: DWord;

    procedure SetDelay(const Value: DWord);
  public
    constructor Create; overload;
    constructor Create(Proc: TCallbackProc; const Arguments: TProcArguments = NIL;
      Delay: DWord = 0); overload;
    constructor Create(ObjectProc: TObjectCallbackProc; const Arguments: TProcArguments = NIL;
      Delay: DWord = 0); overload;
    destructor Destroy; override;

    property Handle: DWord read FHandle;
    property Delay: DWord read FDelay write SetDelay;

    function Running: Boolean;
    procedure Run;
    procedure Stop;
    procedure Restart;
  end;
                        
function ProcArguments(const Pointers: array of const): TProcArguments;

implementation

uses SysUtils, MMSystem;

const
  TimeOutExitCode = DWord(-2);
  MinTimerDelay   = 10;  // any TMMTimer Delay will be at least that long. 

function ProcArguments(const Pointers: array of const): TProcArguments;
var
  I: Integer;
begin
  SetLength(Result, Length(Pointers));
  for I := 0 to Length(Pointers) - 1 do
    Result[I] := Pointers[I].VPointer;
end;

function ProcSettings(ACaller: TObject; AProc: TCallbackProc; AnObjectProc: TObjectCallbackProc;
  IsObject: Boolean; const Arguments: TProcArguments): TProcSettings;
begin
  with Result do
  begin
    Caller := ACaller;
    Proc := AProc;
    ObjectProc := AnObjectProc;
    IsObjectProc := IsObject;
    Args := Arguments;
  end;
end;        

function ProcCaller(Settings: Pointer): DWord; stdcall;
begin
  with TProcSettings(Settings^) do
    if IsObjectProc then
      Result := ObjectProc(Caller, Args)
      else
        Result := Proc(Caller, Args);
end;

{ TSingleThread }            

constructor TSingleThread.Create;
begin
  raise Exception.CreateFmt('Do not use %s.Create without parameters.', [ClassName]);
end;

constructor TSingleThread.Create(Proc: TCallbackProc; const Arguments: TProcArguments = NIL;
  Suspended: Boolean = False);
begin
  FSettings := ProcSettings(Self, Proc, NIL, False, Arguments);
  FHandle := 0;
  FTimeOut := 60;

  if not Suspended then
    Run;
end;

constructor TSingleThread.Create(ObjectProc: TObjectCallbackProc; const Arguments: TProcArguments = NIL;
  Suspended: Boolean = False);
begin
  FSettings := ProcSettings(Self, NIL, ObjectProc, True, Arguments);
  FHandle := 0;
  FTimeOut := 60;

  if not Suspended then
    Run;
end;

destructor TSingleThread.Destroy;
begin
  if GetCurrentThreadID <> FThreadID then
    Kill;
  inherited;
end;

function TSingleThread.Running: Boolean;
begin
  Result := (FHandle <> 0) and not HasFinished;
end;

function TSingleThread.HasFinished: Boolean;
begin
  Result := ExitCode <> STILL_ACTIVE;
end;

function TSingleThread.ExitCode: DWord;
begin
  if FHandle = 0 then
    Result := STILL_ACTIVE
    else if not GetExitCodeThread(FHandle, Result) then
      RaiseLastOSError;;
end;

function TSingleThread.HasTimedOut: Boolean;
begin
  Result := ExitCode = TimeOutExitCode;
end;

procedure TSingleThread.Kill;
begin
  if Running then
    if not TerminateThread(FHandle, ExitCode) then
      RaiseLastOSError;;
end;

procedure TSingleThread.Run;
begin
  if not Running then
    FHandle := CreateThread(NIL, 0, @ProcCaller, @FSettings, 0, FThreadID);
end;

procedure TSingleThread.Wait;
var
  TimeOut: DWord;
begin
  if Running then
  begin
    if FTimeOut = INFINITE then
      TimeOut := INFINITE
      else
        TimeOut := timeGetTime + FTimeOut * 1000;

    while not HasFinished do
      if timeGetTime > TimeOut then   
      begin
        Kill(TimeOutExitCode);
        // although this should make HasFinished return True on next iteration that's not
        //    alwasys the case.
        Break;
      end
        else
          Application.ProcessMessages;
  end;
end;

procedure TSingleThread.SetArguments(const Arguments: TProcArguments);
begin
  FSettings.Args := Arguments;
end;

{ TMMTimer }

constructor TMMTimer.Create;
begin
  raise Exception.CreateFmt('Do not use %s.Create without parameters.', [ClassName]);
end;

constructor TMMTimer.Create(Proc: TCallbackProc; const Arguments: TProcArguments = NIL;
  Delay: DWord = 0);
begin
  FSettings := ProcSettings(Self, Proc, NIL, False, Arguments);
  FHandle := 0;
  SetDelay(Delay);
end;

constructor TMMTimer.Create(ObjectProc: TObjectCallbackProc; const Arguments: TProcArguments = NIL;
  Delay: DWord = 0);
begin
  FSettings := ProcSettings(Self, NIL, ObjectProc, True, Arguments);
  FHandle := 0;
  SetDelay(Delay);
end;

destructor TMMTimer.Destroy;
begin
  Stop;
  inherited;
end;

function TMMTimer.Running: Boolean;
begin
  Result := FHandle <> 0;
end;

procedure TMMTimer.Restart;
begin
  Stop;
  Run;
end;

function TimerLauncher(uTimerID, uMessage: DWord; Settings: Pointer; dw1, dw2: DWord): DWord; stdcall;
begin
  with TProcSettings(Settings^), TMMTimer(Caller) do
    if ProcCaller(Settings) <> 0 then
      Stop
      else if Running then
        FHandle := timeSetEvent(FDelay, FDelay div 10, @TimerLauncher, DWord(Settings), TIME_ONESHOT);

  Result := 1;
end;

procedure TMMTimer.Run;
begin
  FHandle := 1;
  TimerLauncher(0, 0, @FSettings, 0, 0);
end;

procedure TMMTimer.Stop;
begin
  if Running then
    timeKillEvent(FHandle);
  FHandle := 0;
end;

procedure TMMTimer.SetDelay(const Value: DWord);
begin
  FDelay := Value;
  if Value < MinTimerDelay then
    FDelay := MinTimerDelay;
  if Running then
    Restart;
end;

end.
