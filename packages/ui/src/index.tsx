import React from "react";

export const Hello: React.FC<{ name?: string }> = ({ name = "World" }) => {
    return <div style={{ padding: 8, border: "1px solid #ddd" }}>Hello {name}</div>;
};
