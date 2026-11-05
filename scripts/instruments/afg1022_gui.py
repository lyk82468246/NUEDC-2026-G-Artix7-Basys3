"""Tkinter AFG1022 contest controller. Opening the app does not change outputs."""
import json
from pathlib import Path
import queue
import threading
import tkinter as tk
from tkinter import ttk, messagebox, filedialog

from afg1022 import AFG1022, is_afg_resource, resource_manager
from afg_contest_waveform import build, preset


class App:
    def __init__(self, root):
        self.root = root
        root.title('AFG1022 · 周期信号测试台')
        root.geometry('1120x720')
        root.minsize(1060, 720)
        self.events = queue.Queue()
        self.stop = threading.Event()
        self.busy = False
        self.buttons = []
        self.vars = {}
        self.latest = None
        self.status = tk.StringVar(value='未查询仪器；启动程序不会改变当前输出')
        main=ttk.Frame(root,padding=12)
        main.pack(fill='both',expand=True)
        main.columnconfigure(0,weight=1)
        main.rowconfigure(1,weight=1)
        menu=tk.Menu(root)
        files=tk.Menu(menu,tearoff=False)
        for label,command in [('保存参数…',self.save_profile),('载入参数…',self.load_profile),('导出波形 JSON…',self.export)]:
            files.add_command(label=label,command=command)
        menu.add_cascade(label='文件',menu=files)
        menu.add_command(label='模式说明',command=self.show_help)
        menu.add_command(label='通信日志',command=self.show_log)
        root.configure(menu=menu)
        connection=ttk.Frame(main)
        connection.grid(row=0,column=0,sticky='ew',pady=(0,10))
        ttk.Label(connection,text='VISA 资源').pack(side='left')
        self.resource=ttk.Combobox(connection,width=48)
        self.resource.pack(side='left',padx=8,fill='x',expand=True)
        self.button(connection,'扫描设备',self.scan).pack(side='left',padx=3)
        self.button(connection,'查询状态',self.read_status).pack(side='left',padx=3)
        body=ttk.Frame(main)
        body.grid(row=1,column=0,sticky='nsew')
        body.columnconfigure(0,weight=1)
        body.columnconfigure(1,minsize=410)
        body.rowconfigure(0,weight=1)
        left=ttk.Frame(body)
        left.grid(row=0,column=0,sticky='nsew',padx=(0,12))
        left.columnconfigure(0,weight=1)
        left.rowconfigure(1,weight=1)
        panel=ttk.LabelFrame(left,text='公共设置 · 分量幅度为峰值 mV',padding=10)
        panel.grid(row=0,column=0,sticky='ew',pady=(0,10))
        self.common_panel=panel
        for col in (1,3,5):panel.columnconfigure(col,weight=1)
        for col, (key, label, choices) in enumerate([
            ('mode', '题目模式', ('A', 'B', 'C')),
            ('points', '表长', (256,512,1000,1024,2048,4096,8192)),
            ('load', '负载显示', ('HIGHZ','50')),
        ]):
            ttk.Label(panel, text=label).grid(row=0,column=col*2, padx=4)
            var = tk.StringVar()
            self.vars[key] = var
            ttk.Combobox(panel, textvariable=var, values=choices, state='readonly', width=8).grid(row=0,column=col*2+1,padx=4,sticky='ew')
        self.vars['channel']=tk.StringVar(value='1')
        ttk.Label(panel,text='输出通道').grid(row=1,column=0,padx=4)
        ttk.Combobox(panel,textvariable=self.vars['channel'],values=(1,2),state='readonly',width=8).grid(row=1,column=1,padx=4,sticky='ew')
        self.field(panel,'f0_khz','基频 kHz',1,2)
        self.count = tk.StringVar(value='3')
        ttk.Label(panel,text='分量数').grid(row=1,column=4,pady=8)
        ttk.Combobox(panel,textvariable=self.count,values=('2','3'),state='readonly',width=8).grid(row=1,column=5,padx=4,sticky='ew')
        self.button(panel, '载入该模式示例', self.load_preset).grid(row=2,column=0,columnspan=6,sticky='e',pady=(2,12))
        harmonics=ttk.Frame(panel)
        harmonics.grid(row=3,column=0,columnspan=6,sticky='ew')
        for col,title in enumerate(('分量','谐波阶数','峰值 / mV','相位 / °')):
            ttk.Label(harmonics,text=title,anchor='w').grid(row=0,column=col,sticky='ew',padx=6,pady=(0,6))
            harmonics.columnconfigure(col,weight=0 if col==0 else 1)
        self.rows=[]
        for i in range(3):
            row=[]
            ttk.Label(harmonics,text=f'F{i+1}').grid(row=1+i,column=0,padx=6,pady=5,sticky='w')
            for col,key in enumerate(('order','peak_mv','phase_deg'),start=1):
                v=tk.StringVar()
                ttk.Entry(harmonics,textvariable=v,width=10).grid(row=1+i,column=col,padx=6,pady=5,sticky='ew')
                row.append((key,v))
            self.rows.append(dict(row))
        sidebar=ttk.Frame(body)
        sidebar.grid(row=0,column=1,sticky='nsew')
        sidebar.columnconfigure(0,weight=1)
        self.parameter_sidebar=sidebar
        c_panel=ttk.LabelFrame(sidebar,text='C 专属设置',padding=8)
        c_panel.grid(row=0,column=0,sticky='ew')
        c_panel.columnconfigure(1,weight=1)
        self.field(c_panel,'interference_khz','干扰频率 kHz',0,0)
        self.field(c_panel,'interference_vpp_mv','干扰 mVpp',1,0)
        self.field(c_panel,'interference_phase_deg','干扰相位 °',2,0)
        self.vars['part']=tk.StringVar()
        ttk.Label(c_panel,text='输出组成').grid(row=3,column=0,pady=2,sticky='w')
        ttk.Combobox(c_panel,textvariable=self.vars['part'],values=('混合信号','仅被测信号','仅干扰'),state='readonly',width=14).grid(row=3,column=1,padx=4,sticky='ew')
        results=ttk.Frame(sidebar)
        results.grid(row=1,column=0,sticky='ew',pady=(10,0))
        self.create_results(results)
        self.canvas=tk.Canvas(left,height=180,bg='#101c2b',highlightthickness=0)
        self.canvas.grid(row=1,column=0,sticky='nsew')
        self.canvas.bind('<Configure>',lambda e:self.draw())
        self.log_window=tk.Toplevel(root)
        self.log_window.title('AFG1022 · 通信日志')
        self.log_window.geometry('800x400')
        self.log_window.withdraw()
        self.log_window.protocol('WM_DELETE_WINDOW',self.log_window.withdraw)
        self.log=tk.Text(self.log_window,wrap='word',state='disabled')
        log_scroll=ttk.Scrollbar(self.log_window,command=self.log.yview)
        log_scroll.pack(side='right',fill='y')
        self.log.pack(fill='both',expand=True)
        self.log.configure(yscrollcommand=log_scroll.set)
        actions=ttk.Frame(main)
        actions.grid(row=2,column=0,sticky='ew',pady=(10,6))
        for label,fn in [('预览 / 校验',self.preview),('上传（保持 OFF）',lambda:self.apply(False)),('上传并开启',lambda:self.apply(True))]:
            self.button(actions,label,fn).pack(side='left',padx=(0,6))
        ttk.Button(actions,text='关闭两路输出',command=self.off).pack(side='right')
        ttk.Button(actions,text='通信日志',command=self.show_log).pack(side='right',padx=6)
        status_label=ttk.Label(main,textvariable=self.status,foreground='#475569',wraplength=1050)
        status_label.grid(row=3,column=0,sticky='ew')
        ttk.Label(main,text='上传覆盖共享 EMEM；关闭窗口会保留输出。停止信号请点“关闭两路输出”。',foreground='#64748b').grid(row=4,column=0,sticky='w',pady=(3,0))
        self.set_profile(preset('A'))
        root.after(100,self.poll)
        root.protocol('WM_DELETE_WINDOW',self.close)

    def button(self,parent,label,fn):
        b=ttk.Button(parent,text=label,command=fn)
        self.buttons.append(b)
        return b

    def field(self,parent,key,label,row,col):
        ttk.Label(parent,text=label).grid(row=row,column=col,pady=2)
        self.vars[key]=tk.StringVar()
        ttk.Entry(parent,textvariable=self.vars[key],width=11).grid(row=row,column=col+1,padx=4)

    def profile(self):
        p={k:v.get() for k,v in self.vars.items() if k!='channel'}
        p['points']=int(p['points'])
        p['tones']=[{k:v.get() for k,v in row.items()} for row in self.rows[:int(self.count.get())]]
        return p

    def set_profile(self,p):
        build(p)  # Validate before changing the controls.
        for k,v in self.vars.items():
            if k in p:
                v.set(p[k])
        self.count.set(str(len(p['tones'])))
        for i,row in enumerate(self.rows):
            for k,v in row.items():
                v.set(p['tones'][i][k] if i<len(p['tones']) else dict(order=4,peak_mv=10,phase_deg=0)[k])
        self.preview()

    def load_preset(self):
        self.set_profile(preset(self.vars['mode'].get()))

    def create_results(self, parent):
        style=ttk.Style(self.root)
        style.configure('ResultCaption.TLabel',foreground='#64748b')
        style.configure('ResultValue.TLabel',font=('Segoe UI',11,'bold'),foreground='#18324e')
        style.configure('ResultNote.TLabel',foreground='#64748b')
        style.configure('ResultWarning.TLabel',foreground='#a65a00')
        area=ttk.Frame(parent)
        area.pack(fill='x')
        area.columnconfigure(0,weight=1)
        signal=ttk.LabelFrame(area,text='被测信号 · 理论值',padding=(10,6))
        signal.grid(row=0,column=0,sticky='ew')
        output=ttk.LabelFrame(area,text='输出设置',padding=(10,6))
        output.grid(row=1,column=0,sticky='ew',pady=(8,0))
        self.result_vars={}
        for col,key,label in [(0,'upp','Upp'),(3,'rms','RMS')]:
            ttk.Label(signal,text=label,style='ResultCaption.TLabel').grid(row=0,column=col,sticky='w')
            v=tk.StringVar(value='—'); self.result_vars[key]=v
            ttk.Label(signal,textvariable=v,anchor='e',style='ResultValue.TLabel',width=9).grid(row=0,column=col+1,sticky='e',padx=(6,4))
            ttk.Label(signal,text='mV',style='ResultCaption.TLabel').grid(row=0,column=col+2,sticky='w')
        ttk.Separator(signal).grid(row=1,column=0,columnspan=6,sticky='ew',pady=7)
        for col,text in [(0,'分量'),(1,'频率 / kHz'),(3,'峰值 / mV'),(5,'相位 / °')]:
            ttk.Label(signal,text=text,anchor='e' if col else 'w',style='ResultCaption.TLabel').grid(row=2,column=col, columnspan=2 if col in (1,3) else 1,sticky='ew',padx=(0,6))
        self.component_vars=[]
        for i in range(3):
            values=[tk.StringVar(value='—') for _ in range(3)]
            self.component_vars.append(values)
            ttk.Label(signal,text=f'F{i+1}',style='ResultCaption.TLabel').grid(row=3+i,column=0,sticky='w',pady=2)
            for v,col,span in zip(values,(1,3,5),(2,2,1)):
                ttk.Label(signal,textvariable=v,anchor='e').grid(row=3+i,column=col,columnspan=span,sticky='ew',padx=(0,6),pady=2)
        for row,(key,label,unit) in enumerate([
            ('repeat','整表频率','Hz'),('rate','等效采样率','MSa/s'),
            ('scale','满量程','mVpp'),('part','输出组成','')]):
            ttk.Label(output,text=label,style='ResultCaption.TLabel').grid(row=row,column=0,sticky='w',pady=1)
            v=tk.StringVar(value='—'); self.result_vars[key]=v
            ttk.Label(output,textvariable=v,anchor='e',width=12).grid(row=row,column=1,sticky='ew',padx=(18,8),pady=1)
            ttk.Label(output,text=unit,style='ResultCaption.TLabel',width=7).grid(row=row,column=2,sticky='w')
        output.columnconfigure(1,weight=1)
        self.result_note=tk.StringVar()
        self.result_warning=tk.StringVar()
        self.note_label=ttk.Label(area,textvariable=self.result_note,style='ResultNote.TLabel',wraplength=1000)
        self.note_label.grid(row=2,column=0,sticky='w',pady=(6,0))
        self.warning_label=ttk.Label(area,textvariable=self.result_warning,style='ResultWarning.TLabel',wraplength=1000)
        self.warning_label.grid(row=3,column=0,sticky='w',pady=(4,0))
        area.bind('<Configure>',lambda e:[label.configure(wraplength=max(200,e.width-8)) for label in (self.note_label,self.warning_label)])

    def update_results(self, data=None):
        for var in self.result_vars.values():var.set('—')
        for row in self.component_vars:
            for var in row:var.set('—')
        if data is None:
            self.result_note.set('')
            self.result_warning.set('参数无效；请修正后重新预览。')
            self.warning_label.grid()
            return
        for key,value in dict(upp=f"{data['clean_vpp_mv']:.3f}",rms=f"{data['clean_rms_mv']:.3f}",
                              repeat=f"{data['repeat_hz']:,.2f}",rate=f"{data['table_sample_rate_hz']/1e6:,.3f}",
                              scale=f"{data['config']['vpp']*1000:,.3f}",part=data['part']).items():
            self.result_vars[key].set(value)
        for row,tone in zip(self.component_vars,data['tones']):
            for var,value in zip(row,(tone['hz']/1000,tone['peak_v']*1000,tone['phase_deg'])):
                var.set(f'{value:,.3f}')
        notes=[w for w in data['warnings'] if w.startswith('HIGHZ')]
        warnings=[w for w in data['warnings'] if not w.startswith('HIGHZ')]
        self.result_note.set('\n'.join(notes))
        self.result_warning.set('\n'.join(warnings))
        if notes:self.note_label.grid()
        else:self.note_label.grid_remove()
        if warnings:self.warning_label.grid()
        else:self.warning_label.grid_remove()

    def preview(self):
        try:
            self.latest=build(self.profile())
            d=self.latest
            self.update_results(d)
            self.draw()
            return d
        except Exception as e:
            self.latest=None
            self.canvas.delete('all')
            self.update_results()
            messagebox.showerror('参数检查',str(e))

    def draw(self):
        self.canvas.delete('all')
        if not self.latest:return
        d=self.latest
        w=max(self.canvas.winfo_width(),100); h=max(self.canvas.winfo_height(),100)
        clean=d['preview_clean']; top=max(abs(v) for v in clean) or 1
        center=(h+24)/2; amplitude=max(12,(h-70)/2)
        self.canvas.create_text(16,18,anchor='w',text='被测信号 1 周期（不含干扰）',fill='#e5ecf6')
        for fraction in (.25,.5,.75):
            x=20+(w-40)*fraction
            self.canvas.create_line(x,38,x,h-20,fill='#213249')
        self.canvas.create_line(20,center,w-20,center,fill='#41536a')
        self.canvas.create_text(w-16,18,anchor='e',text=f"Upp {d['clean_vpp_mv']:.3f} mV",fill='#9cb1c9')
        coords=[]
        for i,v in enumerate(clean):coords.extend((20+i/(len(clean)-1)*(w-40),center-v/top*amplitude))
        self.canvas.create_line(*coords,fill='#4ed5c5',width=2)

    def show_help(self):
        messagebox.showinfo('A / B / C 模式说明',
            'A：所有分量 10～200 kHz，被测 Upp 100～250 mV。\n\n'
            'B：所有分量 10～500 kHz，被测 Upp 50～250 mV。\n\n'
            'C：B 信号 + 单频干扰，干扰 ≥1 MHz，标准 200 mVpp。\n'
            '本工具干扰范围 1～10 MHz；非标准幅度标记为扩展测试。\n\n'
            '分量幅度为峰值 mV，相位为度。预览显示被测信号，不含干扰。\n'
            '切换 C 的输出组成可分别检查被测信号、干扰及混合波。',parent=self.root)

    def show_log(self):
        self.log_window.deiconify()
        self.log_window.lift()

    def write_log(self,text):
        self.log.configure(state='normal'); self.log.insert('end',text+'\n'); self.log.see('end'); self.log.configure(state='disabled')

    def run(self,label,fn):
        if self.busy:return
        self.busy=True; self.stop.clear()
        for b in self.buttons:b.configure(state='disabled')
        self.status.set(label+'…')
        def worker():
            try:self.events.put(('ok',label,fn()))
            except Exception as e:self.events.put(('error',label,str(e)+'\n'+'\n'.join(getattr(e,'__notes__',[]))))
        threading.Thread(target=worker,daemon=True).start()

    def poll(self):
        try:
            while True:
                kind,label,result=self.events.get_nowait()
                self.busy=False
                for b in self.buttons:b.configure(state='normal')
                if kind=='error':
                    self.status.set(label+'失败；以日志为准')
                    self.write_log(str(result)); messagebox.showerror(label,str(result))
                else:
                    if label=='扫描设备':
                        self.resource['values']=result
                        if len(result)==1:self.resource.set(result[0])
                    self.status.set(label+'完成；'+('输出状态见下方实际回读' if label!='扫描设备' else '请选择资源'))
                    self.write_log(json.dumps(result,ensure_ascii=False,indent=2))
                if self.stop.is_set() and label in ('扫描设备','查询状态'):
                    self.off()
        except queue.Empty:pass
        self.root.after(100,self.poll)

    def scan(self):
        def work():
            rm=resource_manager()
            try:return [r for r in rm.list_resources('USB?*::INSTR') if is_afg_resource(r)]
            finally:rm.close()
        self.run('扫描设备',work)

    def read_status(self):
        resource=self.resource.get() or None
        def work():
            with AFG1022(resource) as d:return dict(identity=d.identity,resource=d.resource,channels=[d.settings(1),d.settings(2)])
        self.run('查询状态',work)

    def apply(self,on):
        data=self.preview()
        if data is None:return
        resource=self.resource.get() or None; ch=int(self.vars['channel'].get())
        def work():
            with AFG1022(resource) as d:
                try:
                    upload=d.upload_arb(data['samples'])
                    if self.stop.is_set():
                        for c in (1,2):d.output_off(c)
                    elif on:
                        d.output_on(ch,**data['config'])
                    else:d.configure(ch,**data['config'])
                    if self.stop.is_set():
                        for c in (1,2):d.output_off(c)
                    return dict(identity=d.identity,upload=upload,channels=[d.settings(1),d.settings(2)])
                except BaseException:
                    d._emergency_off()
                    raise
        self.run('上传并开启' if on else '上传保持关闭',work)

    def off(self):
        if self.busy:
            self.stop.set()
            self.status.set('已请求停止；当前通信结束后关闭两路，请等待回读确认')
            return
        resource=self.resource.get() or None
        def work():
            with AFG1022(resource) as d:
                errors=[]
                for ch in (1,2):
                    try:d.output_off(ch)
                    except Exception as e:errors.append(str(e))
                if errors:
                    d._emergency_off()
                    raise RuntimeError('OFF 未确认，请核对面板：'+'; '.join(errors))
                return dict(channels=[d.settings(1),d.settings(2)])
        self.run('关闭两路输出',work)

    def save_profile(self):
        if self.preview() is None:return
        path=filedialog.asksaveasfilename(defaultextension='.json',filetypes=[('参数 JSON','*.json')])
        if path:Path(path).write_text(json.dumps(self.profile(),ensure_ascii=False,indent=2),encoding='utf-8')

    def load_profile(self):
        path=filedialog.askopenfilename(filetypes=[('参数 JSON','*.json')])
        if path:
            try:self.set_profile(json.loads(Path(path).read_text(encoding='utf-8-sig')))
            except Exception as e:messagebox.showerror('载入失败',str(e))

    def export(self):
        data=self.preview()
        if data is None:return
        path=filedialog.asksaveasfilename(defaultextension='.json',filetypes=[('采样表 JSON','*.json')])
        if path:Path(path).write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')

    def close(self):
        if self.busy:
            self.stop.set()
            self.status.set('通信进行中；已请求停止，请等待完成后再关闭窗口')
        else:self.root.destroy()


if __name__=='__main__':
    App(tk.Tk()).root.mainloop()
