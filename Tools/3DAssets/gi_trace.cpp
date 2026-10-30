// Dependency-free, offline-only triangle BVH used by bake_gi.py. No runtime renderer linkage.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <memory>
#include <numeric>
#include <vector>
#if defined(_WIN32)
#define GI_API extern "C" __declspec(dllexport)
#else
#define GI_API extern "C" __attribute__((visibility("default")))
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
struct Triangle { V a,e1,e2,lo,hi,center; };
struct Node { V lo,hi; int begin,count,left=-1,right=-1; };
struct BVH {
    std::vector<Triangle> triangles;
    std::vector<int> order;
    std::vector<Node> nodes;
    int build(int begin,int end) {
        Node n{{INFINITY,INFINITY,INFINITY},{-INFINITY,-INFINITY,-INFINITY},begin,end-begin};
        for(int i=begin;i<end;++i) { auto &t=triangles[order[i]]; n.lo=minimum(n.lo,t.lo); n.hi=maximum(n.hi,t.hi); }
        int index=int(nodes.size()); nodes.push_back(n);
        if(end-begin>8) {
            V size=n.hi-n.lo;
            int axis=size.x>size.y?(size.x>size.z?0:2):(size.y>size.z?1:2),middle=(begin+end)/2;
            std::nth_element(order.begin()+begin,order.begin()+middle,order.begin()+end,
                [&](int a,int b) { return triangles[a].center[axis]<triangles[b].center[axis]; });
            int left=build(begin,middle),right=build(middle,end);
            nodes[index].left=left; nodes[index].right=right; nodes[index].count=0;
        }
        return index;
    }
    bool box(const Node &n,V origin,V direction,float limit,float near) const {
        float lo=near,hi=limit;
        for(int i=0;i<3;++i) {
            if(std::abs(direction[i])<1e-12f) { if(origin[i]<n.lo[i]||origin[i]>n.hi[i]) return false; continue; }
            float a=(n.lo[i]-origin[i])/direction[i],b=(n.hi[i]-origin[i])/direction[i];
            lo=std::max(lo,std::min(a,b)); hi=std::min(hi,std::max(a,b));
            if(hi<lo) return false;
        }
        return true;
    }
    void trace(V origin,V direction,float near,float &distance,int &hit) const {
        // Median splits give logarithmic depth; 128 entries covers every supported input.
        std::array<int,128> stack{}; int count=1; stack[0]=0; hit=-1;
        while(count) {
            const Node &node=nodes[stack[--count]];
            if(!box(node,origin,direction,distance,near)) continue;
            if(!node.count) { stack[count++]=node.left; stack[count++]=node.right; continue; }
            for(int i=node.begin;i<node.begin+node.count;++i) {
                int id=order[i]; const auto &t=triangles[id]; V h=cross(direction,t.e2);
                float determinant=dot(t.e1,h);
                if(std::abs(determinant)<1e-9f) continue;
                float inverse=1/determinant; V s=origin-t.a;
                float u=dot(s,h)*inverse; if(u<0||u>1) continue;
                V q=cross(s,t.e1); float v=dot(direction,q)*inverse; if(v<0||u+v>1) continue;
                float d=dot(t.e2,q)*inverse;
                if(d>near&&d<distance) { distance=d; hit=id; }
            }
        }
    }
};
GI_API void *gi_create(const float *positions,int count) noexcept {
    if(!positions||count<=0||count>5000000) return nullptr;
    try {
        auto b=std::make_unique<BVH>(); b->triangles.reserve(count); b->order.resize(count);
        for(int i=0;i<count;++i) {
            const float *p=positions+i*9; V a{p[0],p[1],p[2]},v{p[3],p[4],p[5]},w{p[6],p[7],p[8]};
            b->triangles.push_back({a,v-a,w-a,minimum(a,minimum(v,w)),maximum(a,maximum(v,w)),(a+v+w)*(1.f/3)});
        }
        std::iota(b->order.begin(),b->order.end(),0); b->build(0,count); return b.release();
    } catch(...) { return nullptr; }
}
GI_API void gi_destroy(void *b) noexcept { delete static_cast<BVH*>(b); }
GI_API void gi_trace(void *b,const float *origins,const float *directions,int count,float near,float far,float *distances,int32_t *hits) noexcept {
    if(!b||!origins||!directions||!distances||!hits||count<0) return;
    const auto &tree=*static_cast<BVH*>(b);
    for(int i=0;i<count;++i) {
        V o{origins[i*3],origins[i*3+1],origins[i*3+2]},d{directions[i*3],directions[i*3+1],directions[i*3+2]};
        distances[i]=far; tree.trace(o,d,near,distances[i],hits[i]);
    }
}
