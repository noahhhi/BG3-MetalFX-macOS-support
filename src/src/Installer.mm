// User-owned installation and surgical Steam/LSX updates; no Python runtime needed.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <string>
#include <vector>
#include <stdexcept>
#include <unistd.h>

static NSString *const UUID = @"f3a7c1e2-9b4d-4e5a-8c6f-1d2e3f4a5b6c";
static NSFileManager *fm;
static void require(BOOL ok, NSString *why) { if (!ok) @throw [NSException exceptionWithName:@"InstallError" reason:why userInfo:nil]; }
static NSData *read(NSString *p) { NSData *d=[NSData dataWithContentsOfFile:p]; require(d!=nil,[@"Cannot read " stringByAppendingString:p]); return d; }
static NSString *text(NSData *d) { NSString *s=[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]; require(s!=nil,@"Invalid UTF-8 configuration"); return s; }
static NSData *utf8(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }
static NSString *join(NSString *p, NSString *n) { return [p stringByAppendingPathComponent:n]; }
static void write(NSString *p,NSData *d) {
    NSError *e=nil; require([fm createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&e],e.localizedDescription);
    require([d writeToFile:p options:NSDataWritingAtomic error:&e],e.localizedDescription);
}

struct Token { std::string value; size_t start,end; };
struct Node { Token key,value; bool object=false; std::vector<Node> children; };
class VDF {
    std::string source; size_t pos=0;
    Token token() {
        while (pos<source.size()) {
            if (isspace((unsigned char)source[pos])) { pos++; continue; }
            if (source.compare(pos,2,"//")==0) { while(pos<source.size() && source[pos]!='\n')pos++; continue; }
            break;
        }
        Token t{{},pos,pos}; if(pos==source.size())return t;
        char c=source[pos++];
        if(c=='{' || c=='}') { t.value=c; t.end=pos; return t; }
        require(c=='"',@"Malformed Steam VDF token");
        bool closed=false;
        while(pos<source.size()) {
            c=source[pos++]; if(c=='"') {closed=true;break;}
            if(c=='\\') { require(pos<source.size(),@"Truncated VDF escape"); c=source[pos++]; if(c=='n')c='\n'; else if(c=='t')c='\t'; }
            t.value+=c;
        }
        require(closed,@"Unclosed Steam VDF string"); t.end=pos; return t;
    }
    std::vector<Node> parse(bool nested, Token *closing) {
        std::vector<Node> out;
        for (;;) {
            Token key=token();
            if(key.start==key.end) { require(!nested,@"Unclosed Steam VDF object"); break; }
            if(key.value=="}") { require(nested,@"Unexpected VDF closing brace"); *closing=key; break; }
            Node n; n.key=key; n.value=token();
            require(n.value.start!=n.value.end,@"Missing Steam VDF value");
            if(n.value.value=="{") { n.object=true; n.children=parse(true,&n.value); }
            out.push_back(n);
        }
        return out;
    }
public:
    std::vector<Node> nodes;
    explicit VDF(NSString *s):source(s.UTF8String) { nodes=parse(false,nullptr); }
    static Node *find(std::vector<Node>& ns,const char *key) { for(auto &n:ns)if(strcasecmp(n.key.value.c_str(),key)==0)return &n;return nullptr; }
    Node *app() {
        auto *n=find(nodes,"UserLocalConfigStore");
        for (const char *key:{"Software","Valve","Steam","apps","1086940"}) { if(!n||!n->object)return nullptr;n=find(n->children,key); }
        return n && n->object ? n : nullptr;
    }
    static std::string quote(NSString *s) {
        std::string out="\""; for(char c:std::string(s.UTF8String)) { if(c=='\\'||c=='"')out+='\\'; if(c=='\n')out+="\\n";else if(c=='\t')out+="\\t";else out+=c; } return out+'"';
    }
    NSString *get(Node *app) { Node *n=find(app->children,"LaunchOptions");return n ? @(n->value.value.c_str()) : nil; }
    NSData *set(Node *app,NSString *value) {
        Node *n=find(app->children,"LaunchOptions");
        if(n) {
            if(value)source.replace(n->value.start,n->value.end-n->value.start,quote(value));
            else source.erase(n->key.start,n->value.end-n->key.start);
        } else if(value) source.insert(app->value.start,"\t\"LaunchOptions\"\t\t"+quote(value)+"\n\t");
        return [NSData dataWithBytes:source.data() length:source.size()];
    }
};

static NSXMLElement *child(NSXMLElement *p,NSString *name,NSString *ident) {
    for(NSXMLNode *n in p.children) if([n isKindOfClass:[NSXMLElement class]] && [n.name isEqual:name] && (!ident || [[(NSXMLElement*)n attributeForName:@"id"].stringValue isEqual:ident])) return (NSXMLElement*)n;
    return nil;
}
static NSXMLElement *element(NSXMLElement *p,NSString *name,NSString *ident) {
    NSXMLElement *e=child(p,name,ident);if(e)return e;
    e=[NSXMLElement elementWithName:name];if(ident)[e addAttribute:[NSXMLNode attributeWithName:@"id" stringValue:ident]];[p addChild:e];return e;
}
static void attr(NSXMLElement *p,NSString *key,NSString *type,NSString *value) {
    NSXMLElement *a=[NSXMLElement elementWithName:@"attribute"];
    for(NSString *k in @[@"id",@"type",@"value"]) [a addAttribute:[NSXMLNode attributeWithName:k stringValue:([k isEqual:@"id"]?key:([k isEqual:@"type"]?type:value))]];
    [p addChild:a];
}
static NSData *modsettings(NSData *data,BOOL install) {
    NSError *e=nil; NSXMLDocument *doc=[[NSXMLDocument alloc] initWithData:data options:NSXMLNodePreserveAll error:&e];
    require(doc!=nil,e.localizedDescription);
    NSXMLElement *r=child(child(doc.rootElement,@"region",@"ModuleSettings"),@"node",@"root");
    require(r!=nil,@"Unknown modsettings.lsx structure");NSXMLElement *children=element(r,@"children",nil);
    for(NSString *idn in @[@"ModOrder",@"Mods"]) {
        NSXMLElement *group=child(children,@"node",idn);if(!group && !install)continue;
        if(!group)group=element(children,@"node",idn);
        NSXMLElement *list=element(group,@"children",nil);
        for(NSXMLNode *n in [list.children copy]) if([n isKindOfClass:[NSXMLElement class]]) {
            NSXMLElement *a=child((NSXMLElement*)n,@"attribute",@"UUID");if([[a attributeForName:@"value"].stringValue isEqual:UUID])[n detach];
        }
        if(install) {
            NSXMLElement *n=[NSXMLElement elementWithName:@"node"];
            BOOL order=[idn isEqual:@"ModOrder"];
            [n addAttribute:[NSXMLNode attributeWithName:@"id" stringValue:order?@"Module":@"ModuleShortDesc"]];
            attr(n,@"UUID",@"guid",UUID);
            if(!order) {attr(n,@"Folder",@"LSString",@"BG3MetalFX");attr(n,@"Name",@"LSString",@"BG3MetalFX");attr(n,@"MD5",@"LSString",@"");attr(n,@"PublishHandle",@"uint64",@"0");attr(n,@"Version64",@"int64",@"36028797018963968");}
            [list addChild:n];
        }
    }
    return [doc XMLDataWithOptions:NSXMLNodePrettyPrint];
}

int main(int argc,char **argv) {
 @autoreleasepool { @try {
    fm=NSFileManager.defaultManager;
    require(geteuid()!=0,@"Run BG3 MetalFX as the logged-in user, not root.");
    require(argc>=2,@"Usage: bg3mf_installer install --payload DIR | uninstall");
    BOOL install=strcmp(argv[1],"install")==0;
    require(install || strcmp(argv[1],"uninstall")==0,@"Unknown action");
    NSString *home=NSHomeDirectory(),*payload=nil;BOOL test=NO;
    for(int i=2;i<argc;i++) {
        require(i+1<argc,@"Missing option value");NSString *key=@(argv[i++]),*value=@(argv[i]);
        if([key isEqual:@"--payload"])payload=value;
        else if([key isEqual:@"--test-home"]) { require([value containsString:@".bg3mf-test-"] && ![value isEqual:home],@"Test home must be an isolated .bg3mf-test- directory"); home=value; test=YES; }
        else require(NO,@"Unknown option");
    }
    if(!test) for(NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        NSString *bid=app.bundleIdentifier?:@"",*name=app.localizedName?:@"";
        require(![bid isEqual:@"com.valvesoftware.steam"] && ![name isEqual:@"Baldur's Gate 3"] && ![name isEqual:@"bg3"],@"Quit Steam and Baldur's Gate 3 before installing or uninstalling / 请先退出 Steam 和博德之门 3。");
    }
    NSString *dest=join(home,@"Library/Application Support/BG3MetalFX"), *statePath=join(dest,@"install-state.json");
    NSString *game=join(home,@"Documents/Larian Studios/Baldur's Gate 3"),*steam=join(home,@"Library/Application Support/Steam");
    NSString *launcher=join(dest,@"bg3mf_steam_launcher"), *pak=join(game,@"Mods/BG3MetalFX.pak");
    NSMutableDictionary *state=[NSMutableDictionary dictionary];
    if([fm fileExistsAtPath:statePath]) { id s=[NSJSONSerialization JSONObjectWithData:read(statePath) options:NSJSONReadingMutableContainers error:nil]; require([s isKindOfClass:NSDictionary.class],@"Invalid install state");state=s; }
    NSMutableDictionary *launchState=[state[@"launchOptions"] mutableCopy]?:[NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*,NSData*> *writes=[NSMutableDictionary dictionary];
    NSMutableArray<NSString*> *deletes=[NSMutableArray array];
    NSUInteger matches=0;
    for(NSString *account in [fm contentsOfDirectoryAtPath:join(steam,@"userdata") error:nil]) {
        NSString *path=join(join(join(steam,@"userdata"),account),@"config/localconfig.vdf");
        if(![fm fileExistsAtPath:path])continue;
        VDF v(text(read(path)));Node *app=v.app();if(!app)continue;matches++;
        NSString *current=v.get(app);
        if(install) {
            NSDictionary *saved=launchState[path];NSString *before=current;
            if(saved && [current isEqual:saved[@"installed"]])before=saved[@"before"]==NSNull.null?nil:saved[@"before"];
            else if([current containsString:@"bg3mf_steam_launcher"]) {
                // Migrate v1's wrapper only. Never restore a whole legacy VDF backup.
                NSRegularExpression *rx=[NSRegularExpression regularExpressionWithPattern:@"(?:\\\"[^\\\"]*/bg3mf_steam_launcher\\\"|[^\\s\\\"]*/bg3mf_steam_launcher)\\s*" options:0 error:nil];
                before=[rx stringByReplacingMatchesInString:current options:0 range:NSMakeRange(0,current.length) withTemplate:@""];
                require(![before containsString:@"bg3mf_steam_launcher"],@"Cannot safely migrate the existing launch option");
                if([before isEqual:@"%command%"])before=nil;
            }
            NSString *prefix=[NSString stringWithFormat:@"\"%@\" ",launcher];
            NSString *installed;
            if([before containsString:@"%command%"]) installed=[before stringByReplacingOccurrencesOfString:@"%command%" withString:[prefix stringByAppendingString:@"%command%"]];
            else installed=[prefix stringByAppendingFormat:@"%%command%%%@%@",before.length?@" ":@"",before?:@""];
            launchState[path]=@{@"before":before?:NSNull.null,@"installed":installed};
            writes[path]=v.set(app,installed);
        } else {
            NSDictionary *saved=launchState[path];
            if(saved && [current isEqual:saved[@"installed"]])writes[path]=v.set(app,saved[@"before"]==NSNull.null?nil:saved[@"before"]);
            else require(![current containsString:@"bg3mf_steam_launcher"],@"Steam launch options changed after installation. Remove only the bg3mf_steam_launcher wrapper from BG3 Properties, then run uninstall again.");
        }
    }
    if(install)require(matches>0,@"No BG3 Steam profile found. Launch the game once through Steam, then quit both and retry.");
    NSString *profiles=join(game,@"PlayerProfiles");NSUInteger profileCount=0;
    for(NSString *profile in [fm contentsOfDirectoryAtPath:profiles error:nil]) {
        NSString *path=join(join(profiles,profile),@"modsettings.lsx");if(![fm fileExistsAtPath:path])continue;
        writes[path]=modsettings(read(path),install);profileCount++;
    }
    if(install) {
        require(payload!=nil,@"Missing installer payload");require(profileCount>0,@"No BG3 player profile found. Launch the game once, then retry.");
        for(NSString *name in @[@"libbg3mf_probe.dylib",@"bg3mf_steam_launcher",@"bg3mf_installer",@"uninstall.sh"]) writes[join(dest,name)]=read(join(payload,name));
        NSData *mod=read(join(payload,@"mod/BG3MetalFX.pak"));require(mod.length>=40 && memcmp(mod.bytes,"LSPK",4)==0,@"Invalid localization PAK");writes[pak]=mod;
        writes[join(dest,@"runs/launch_env")]=utf8(@"BG3MF_TEMPORAL=1\nBG3MF_SCALE_PATCH=1\n");
        state[@"launchOptions"]=launchState;state[@"version"]=@"1.0.1";
        writes[statePath]=[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
    } else if([fm fileExistsAtPath:pak])[deletes addObject:pak];
    // Validate every document before modifying anything. Roll back all touched files
    // if a write fails; keep a first-install backup for manual recovery.
    NSMutableDictionary *before=[NSMutableDictionary dictionary];
    for(NSString *path in writes)before[path]=[fm fileExistsAtPath:path]?read(path):NSNull.null;
    for(NSString *path in deletes)before[path]=read(path);
    NSString *backup=join(home,@"Library/Application Support/BG3MetalFX-backup");
    @try {
        if(install && ![fm fileExistsAtPath:join(backup,@"original-files.plist")]) {
            NSMutableDictionary *existing=[NSMutableDictionary dictionary];for(NSString *p in before)if(before[p]!=NSNull.null)existing[p]=before[p];
            write(join(backup,@"original-files.plist"),[NSPropertyListSerialization dataWithPropertyList:existing format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil]);
        }
        for(NSString *path in writes)write(path,writes[path]);
        for(NSString *path in deletes)require([fm removeItemAtPath:path error:nil],@"Cannot remove localization PAK");
        if(install)for(NSString *name in @[@"bg3mf_steam_launcher",@"bg3mf_installer",@"uninstall.sh"])require([fm setAttributes:@{NSFilePosixPermissions:@0755} ofItemAtPath:join(dest,name) error:nil],@"Cannot set executable permissions");
        if(!install && [fm fileExistsAtPath:dest])require([fm removeItemAtPath:dest error:nil],@"Cannot remove injector directory");
    } @catch(NSException *e) {
        for(NSString *path in before) {if(before[path]==NSNull.null)[fm removeItemAtPath:path error:nil];else write(path,before[path]);}
        @throw e;
    }
    printf("BG3 MetalFX %s complete / %s。Game files and saves unchanged.\n",install?"installation":"uninstall",install?"安装完成":"卸载完成");
    return 0;
 } @catch(NSException *e) { fprintf(stderr,"BG3 MetalFX: %s\n",e.reason.UTF8String);return 1; } }
}
