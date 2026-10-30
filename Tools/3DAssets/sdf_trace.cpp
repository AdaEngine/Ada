// Offline signed-distance BVH. No dependency or linkage to the runtime renderer.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <memory>
#include <numeric>
#include <thread>
#include <vector>
#if defined(_WIN32)
#define SDF_API extern "C" __declspec(dllexport)
#else
#define SDF_API extern "C" __attribute__((visibility("default")))
#endif
struct V {
    float x,y,z;
    float operator[](int i) const { return i==0?x:i==1?y:z; }
    V operator+(V b) const { return {x+b.x,y+b.y,z+b.z}; }
    V operator-(V b) const { return {x-b.x,y-b.y,z-b.z}; }
    V operator*(float b) const { return {x*b,y*b,z*b}; }
};
static float dot(V a,V b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
static V cross(V a,V b) { return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}; }
static V minimum(V a,V b) { return {std::min(a.x,b.x),std::min(a.y,b.y),std::min(a.z,b.z)}; }
static V maximum(V a,V b) { return {std::max(a.x,b.x),std::max(a.y,b.y),std::max(a.z,b.z)}; }
static float squared(V a) { return dot(a,a); }
struct Triangle { V a,b,c,lo,hi,center; bool solid; };
struct Node { V lo,hi; int begin,count,left=-1,right=-1,mask=0; };
// Ericson's closest point regions, including a robust degenerate-edge fallback.
static float segmentDistance(V p,V a,V b) {
    V d=b-a; return squared(p-(a+d*std::clamp(dot(p-a,d)/std::max(squared(d),1e-25f),0.f,1.f)));
}
static float triangleDistance(V p,const Triangle &t) {
    V ab=t.b-t.a,ac=t.c-t.a,ap=p-t.a;
    if(squared(cross(ab,ac))<1e-24f) return std::min({segmentDistance(p,t.a,t.b),segmentDistance(p,t.b,t.c),segmentDistance(p,t.c,t.a)});
    float d1=dot(ab,ap),d2=dot(ac,ap); if(d1<=0&&d2<=0) return squared(ap);
    V bp=p-t.b; float d3=dot(ab,bp),d4=dot(ac,bp); if(d3>=0&&d4<=d3) return squared(bp);
    float vc=d1*d4-d3*d2; if(vc<=0&&d1>=0&&d3<=0) return squared(p-(t.a+ab*(d1/(d1-d3))));
    V cp=p-t.c; float d5=dot(ab,cp),d6=dot(ac,cp); if(d6>=0&&d5<=d6) return squared(cp);
    float vb=d5*d2-d1*d6; if(vb<=0&&d2>=0&&d6<=0) return squared(p-(t.a+ac*(d2/(d2-d6))));
    float va=d3*d6-d5*d4;
    if(va<=0&&(d4-d3)>=0&&(d5-d6)>=0) return squared(p-(t.b+(t.c-t.b)*((d4-d3)/((d4-d3)+(d5-d6)))));
    float denominator=1/(va+vb+vc); return squared(p-(t.a+ab*(vb*denominator)+ac*(vc*denominator)));
}
struct BVH {
    std::vector<Triangle> triangles; std::vector<int> order; std::vector<Node> nodes;
    int build(int begin,int end) {
        Node n{{INFINITY,INFINITY,INFINITY},{-INFINITY,-INFINITY,-INFINITY},begin,end-begin};
        for(int i=begin;i<end;++i) { const auto &t=triangles[order[i]]; n.lo=minimum(n.lo,t.lo);n.hi=maximum(n.hi,t.hi);n.mask|=t.solid?1:2; }
        int index=int(nodes.size()); nodes.push_back(n);
        if(end-begin>8) {
            V size=n.hi-n.lo;int axis=size.x>size.y?(size.x>size.z?0:2):(size.y>size.z?1:2),middle=(begin+end)/2;
            std::nth_element(order.begin()+begin,order.begin()+middle,order.begin()+end,
                [&](int a,int b) { return triangles[a].center[axis]<triangles[b].center[axis]; });
            int left=build(begin,middle),right=build(middle,end);nodes[index].left=left;nodes[index].right=right;nodes[index].count=0;
        } return index;
    }
    float boxDistance(const Node &n,V p) const {
        float result=0;for(int i=0;i<3;++i) { float d=std::max({n.lo[i]-p[i],0.f,p[i]-n.hi[i]});result+=d*d; } return result;
    }
    bool rayBox(const Node &n,V origin,V direction) const {
        float lo=1e-7f,hi=INFINITY;
        for(int i=0;i<3;++i) {
            float a=(n.lo[i]-origin[i])/direction[i],b=(n.hi[i]-origin[i])/direction[i];
            lo=std::max(lo,std::min(a,b));hi=std::min(hi,std::max(a,b));if(hi<lo)return false;
        } return true;
    }
    void nearest(V p,float &closed,float &open) const {
        std::array<int,128> stack{};int count=1;stack[0]=0;
        while(count) {
            const auto &n=nodes[stack[--count]];float lower=boxDistance(n,p);
            if((!(n.mask&1)||lower>=closed)&&(!(n.mask&2)||lower>=open)) continue;
            if(n.count) {
                for(int i=n.begin;i<n.begin+n.count;++i) { const auto &t=triangles[order[i]];float d=triangleDistance(p,t);if(t.solid)closed=std::min(closed,d);else open=std::min(open,d); }
            } else {
                int near=n.left,far=n.right;if(boxDistance(nodes[near],p)>boxDistance(nodes[far],p))std::swap(near,far);
                stack[count++]=far;stack[count++]=near;
            }
        }
    }
    // Outward-oriented closed components contribute +1 at exits and -1 at
    // entries. The sum is the number of containing solids, not parity of the
    // combined scene: overlapping solids therefore stay negative in the union.
    int winding(V origin,V direction) const {
        std::array<int,128> stack{};int count=1,result=0;stack[0]=0;
        while(count) {
            const auto &n=nodes[stack[--count]];if(!(n.mask&1)||!rayBox(n,origin,direction))continue;
            if(!n.count) {stack[count++]=n.left;stack[count++]=n.right;continue;}
            for(int i=n.begin;i<n.begin+n.count;++i) {
                const auto &t=triangles[order[i]];if(!t.solid)continue;
                V e1=t.b-t.a,e2=t.c-t.a,h=cross(direction,e2);float determinant=dot(e1,h);
                if(std::abs(determinant)<1e-10f)continue;
                float inv=1/determinant;V s=origin-t.a;float u=dot(s,h)*inv;if(u<0||u>1)continue;
                V q=cross(s,e1);float v=dot(direction,q)*inv;if(v<0||u+v>1)continue;
                if(dot(e2,q)*inv>1e-7f)result+=determinant<0?1:-1;
            }
        } return result;
    }
    float distance(V p,float shell) const {
        float closed=INFINITY,open=INFINITY;nearest(p,closed,open);
        float d=std::sqrt(closed);
        if(d<1e-6f)d=0;
        else if(std::isfinite(d)) {
            // Two non-axis-aligned directions handle rare shared-edge hits.
            // A tie invokes a third deterministic direction.
            bool a=winding(p,{.812371f,.345719f,.469137f})>0;
            bool b=winding(p,{-.237519f,.921337f,.308271f})>0;
            bool inside=a==b?a:winding(p,{.417931f,-.285713f,.862371f})>0;
            if(inside)d=-d;
        }
        return std::min(d,std::sqrt(open)-shell);
    }
};
SDF_API void *sdf_create(const float *vertices,const int32_t *solid,int count) noexcept {
    if(!vertices||!solid||count<=0||count>5000000)return nullptr;
    try {
        auto b=std::make_unique<BVH>();b->triangles.reserve(count);b->order.resize(count);
        for(int i=0;i<count;++i) {
            const float *v=vertices+i*9;V a{v[0],v[1],v[2]},c{v[3],v[4],v[5]},d{v[6],v[7],v[8]};
            b->triangles.push_back({a,c,d,minimum(a,minimum(c,d)),maximum(a,maximum(c,d)),(a+c+d)*(1.f/3),solid[i]!=0});
        }
        std::iota(b->order.begin(),b->order.end(),0);b->build(0,count);return b.release();
    } catch(...) {return nullptr;}
}
SDF_API void sdf_destroy(void *b) noexcept {delete static_cast<BVH*>(b);}
SDF_API void sdf_distance(void *handle,const float *points,int count,float shell,float *output,int workers) noexcept {
    if(!handle||!points||!output||count<0)return;const auto &b=*static_cast<BVH*>(handle);
    auto query=[&](int begin,int end) {for(int i=begin;i<end;++i)output[i]=b.distance({points[i*3],points[i*3+1],points[i*3+2]},shell);};
    workers=std::clamp(workers,1,8);if(workers==1||count<4096){query(0,count);return;}
    std::vector<std::thread> threads;
    for(int i=0;i<workers;++i)threads.emplace_back(query,count*i/workers,count*(i+1)/workers);
    for(auto &thread:threads)thread.join();
}
