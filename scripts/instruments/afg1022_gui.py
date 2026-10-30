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
        root.geometry('1120x850')
        root.minsize(1000, 760)
        self.events = queue.Queue()
        self.stop = threading.Event()
        self.busy = False
        self.buttons = []
        self.vars = {}
        self.latest = None
        self.status = tk.StringVar(value='未查询仪器；启动程序不会改变当前输出')
        main = ttk.Frame(root, padding=14)
        main.pack(fill='both', expand=True)
        connection = ttk.LabelFrame(main, text='仪器', padding=8)
        connection.pack(fill='x')
        ttk.Label(connection, text='VISA 资源').pack(side='left')
        self.resource = ttk.Combobox(connection, width=52)
        self.resource.pack(side='left', padx=8)
        self.button(connection, '扫描设备', self.scan).pack(side='left', padx=3)
        self.button(connection, '查询状态', self.read_status).pack(side='left', padx=3)
        ttk.Label(main, textvariable=self.status, wraplength=1050).pack(fill='x', pady=8)
        panel = ttk.LabelFrame(main, text='参数（分量幅度为峰值 mV；干扰为峰峰值 mVpp）', padding=10)
        panel.pack(fill='x')
        for col, (key, label, choices) in enumerate([
            ('mode', '题目模式', ('A', 'B', 'C')),
            ('points', '表长', (256,512,1000,1024,2048,4096,8192)),
            ('load', '负载显示', ('HIGHZ','50')),
            ('channel', '输出通道', (1,2)),
        ]):
            ttk.Label(panel, text=label).grid(row=0,column=col*2, padx=4)
            var = tk.StringVar(value='1' if key=='channel' else '')
            self.vars[key] = var
            ttk.Combobox(panel, textvariable=var, values=choices, state='readonly', width=10).grid(row=0,column=col*2+1,padx=4)
        self.button(panel, '载入该模式示例', self.load_preset).grid(row=0,column=8,padx=8)
        self.field(panel,'f0_khz','基频 kHz',1,0)
        self.count = tk.StringVar(value='3')
        ttk.Label(panel,text='分量数').grid(row=1,column=2,pady=8)
        ttk.Combobox(panel,textvariable=self.count,values=('2','3'),state='readonly',width=10).grid(row=1,column=3)
        self.rows=[]
        for i in range(3):
            row=[]
            ttk.Label(panel,text=f'分量 {i+1}').grid(row=2+i,column=0,pady=4)
            for col,label,key in [(1,'谐波阶数','order'),(3,'峰值 mV','peak_mv'),(5,'相位 °','phase_deg')]:
                ttk.Label(panel,text=label).grid(row=2+i,column=col)
                v=tk.StringVar()
                ttk.Entry(panel,textvariable=v,width=11).grid(row=2+i,column=col+1,padx=4)
                row.append((key,v))
            self.rows.append(dict(row))
        self.field(panel,'interference_khz','C 干扰 kHz',5,0)
        self.field(panel,'interference_vpp_mv','干扰 mVpp',5,2)
        self.field(panel,'interference_phase_deg','干扰相位 °',5,4)
        self.vars['part']=tk.StringVar()
        ttk.Label(panel,text='C 输出组成').grid(row=6,column=0,pady=6)
        ttk.Combobox(panel,textvariable=self.vars['part'],values=('混合信号','仅被测信号','仅干扰'),state='readonly',width=16).grid(row=6,column=1,columnspan=2)
        ttk.Label(panel,text='A：10～200 kHz / 100～250 mVpp；B、C：10～500 kHz / 50～250 mVpp').grid(row=7,column=0,columnspan=9,sticky='w',pady=5)
        ttk.Label(panel,text='C：单频干扰 ≥1 MHz，标准 200 mVpp。本工具支持 1～10 MHz；偏离标准幅度会标记为扩展测试。').grid(row=8,column=0,columnspan=9,sticky='w')
        actions=ttk.Frame(main)
        actions.pack(fill='x',pady=10)
        for label,fn in [('预览 / 校验',self.preview),('上传（保持 OFF）',lambda:self.apply(False)),('上传并开启',lambda:self.apply(True)),('保存参数',self.save_profile),('载入参数',self.load_profile),('导出波形 JSON',self.export)]:
            self.button(actions,label,fn).pack(side='left',padx=3)
        ttk.Button(actions,text='关闭两路输出',command=self.off).pack(side='right',padx=3)
        self.summary=tk.StringVar()
        ttk.Label(main,textvariable=self.summary,wraplength=1050,justify='left').pack(fill='x')
        self.canvas=tk.Canvas(main,height=190,bg='#101c2b',highlightthickness=0)
        self.canvas.pack(fill='x',pady=8)
        self.canvas.bind('<Configure>',lambda e:self.draw())
        self.log=tk.Text(main,height=8,wrap='word',state='disabled')
        self.log.pack(fill='both',expand=True)
        ttk.Label(main,text='上传覆盖共享 EMEM 并关闭两路；开启总是重新上传当前参数。关闭窗口会保留仪器输出，请按“关闭两路输出”停止。').pack(fill='x',pady=(6,0))
        self.set_profile(preset('A'))
        root.after(100,self.poll)
        root.protocol('WM_DELETE_WINDOW',self.close)

    def button(self,parent,label,fn):
        b=ttk.Button(parent,text=label,command=fn)
        self.buttons.append(b)
        return b

    def field(self,parent,key,label,row,col):
        ttk.Label(parent,text=label).grid(row=row,column=col,pady=6)
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

    def preview(self):
        try:
            self.latest=build(self.profile())
            d=self.latest
            components='；'.join(f"{t['hz']/1000:g} kHz / {t['peak_v']*1000:g} mV peak" for t in d['tones'])
            self.summary.set(f"被测信号：Upp {d['clean_vpp_mv']:.3f} mV，RMS {d['clean_rms_mv']:.3f} mV\n{components}\n整表 {d['repeat_hz']:g} Hz，等效采样 {d['table_sample_rate_hz']/1e6:g} MSa/s，满量程 {d['config']['vpp']*1000:g} mVpp；输出组成：{d['part']}\n"+'\n'.join(d['warnings']))
            self.draw()
            return d
        except Exception as e:
            self.latest=None
            self.canvas.delete('all')
            self.summary.set('参数无效；未改变仪器')
            messagebox.showerror('参数检查',str(e))

    def draw(self):
        self.canvas.delete('all')
        if not self.latest:return
        d=self.latest; w=max(self.canvas.winfo_width(),900); h=190
        clean=d['preview_clean']; top=max(abs(v) for v in clean) or 1
        self.canvas.create_line(20,100,w-20,100,fill='#41536a')
        self.canvas.create_text(20,15,anchor='w',text='被测信号 1 周期（不含干扰）',fill='#e5ecf6')
        coords=[]
        for i,v in enumerate(clean):coords.extend((20+i/(len(clean)-1)*(w*.68-30),100-v/top*65))
        self.canvas.create_line(*coords,fill='#4ed5c5',width=2)
        self.canvas.create_text(w*.72,15,anchor='w',text='分量峰值 mV',fill='#e5ecf6')
        peak=max(t['peak_v'] for t in d['tones'])
        for i,t in enumerate(d['tones']):
            x=w*.75+i*75; y=155-100*t['peak_v']/peak
            self.canvas.create_rectangle(x,y,x+25,155,fill='#6ea7ff',outline='')
            self.canvas.create_text(x+12,y-12,text=f"{t['peak_v']*1000:g}",fill='white')
            self.canvas.create_text(x+12,172,text=f"{t['hz']/1000:g}k",fill='white')

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
